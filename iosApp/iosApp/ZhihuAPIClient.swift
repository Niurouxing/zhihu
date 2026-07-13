import Foundation

extension Error {
    var isNativeRequestCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError { return urlError.code == .cancelled }
        let error = self as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
}

enum ZhihuRequestAuthentication: Sendable {
    case guest
    case accountIfAvailable
    case accountRequired
}

enum ZhihuAPIError: LocalizedError, Equatable {
    case untrustedURL
    case accountUnavailable
    case authenticationRequired
    case invalidResponse
    case httpStatus(Int)
    case malformedPayload

    var errorDescription: String? {
        switch self {
        case .untrustedURL:
            return "请求地址不受信任"
        case .accountUnavailable:
            return "账号信息读取失败，请重新登录后重试"
        case .authenticationRequired:
            return "请登录后重试"
        case .invalidResponse:
            return "服务器返回了无效响应"
        case let .httpStatus(status):
            return "请求失败（HTTP \(status)）"
        case .malformedPayload:
            return "内容格式无法识别"
        }
    }
}

enum ZhihuAPIURLPolicy {
    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil,
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty })
        else { return false }
        return host == "zhihu.com" || host.hasSuffix(".zhihu.com")
    }

    static func allowsAPIRequest(_ url: URL) -> Bool {
        guard allows(url), let host = url.host?.lowercased() else { return false }
        let path = url.path
        switch host {
        case "zhihu.com", "www.zhihu.com":
            return matches(path, root: "/api") || path == "/lastread/touch"
        case "api.zhihu.com":
            return [
                "/collections",
                "/content",
                "/images",
                "/moments",
                "/moments_v3",
                "/notifications",
                "/people",
                "/questions",
                "/read_history",
                "/topstory",
                "/unify-consumption",
            ].contains { matches(path, root: $0) }
        case "daily.zhihu.com", "news-at.zhihu.com":
            return matches(path, root: "/api")
        default:
            return false
        }
    }

    static func allowsCookieDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "zhihu.com" || normalized.hasSuffix(".zhihu.com")
    }

    private static func matches(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix("\(root)/")
    }

    static func validatedPagingURL(_ url: URL?) throws -> URL? {
        guard let url else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ZhihuAPIError.untrustedURL
        }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        guard let upgraded = components.url, allowsAPIRequest(upgraded) else {
            throw ZhihuAPIError.untrustedURL
        }
        return upgraded
    }
}

actor ZhihuAPIClient {
    static let defaultUserAgent =
        "Mozilla/5.0 (X11; U; Linux x86_64; en-US) AppleWebKit/540.0 (KHTML, like Gecko) Ubuntu/10.10 Chrome/9.1.0.0 Safari/540.0"

    private let accountStore: AccountJSONStore
    private let session: URLSession
    private let signer: ZhihuRequestSigning

    init(
        accountStore: AccountJSONStore,
        session: URLSession? = nil,
        signer: ZhihuRequestSigning = ZhihuRequestSigner()
    ) {
        self.accountStore = accountStore
        self.session = session ?? Self.makeSession()
        self.signer = signer
    }

    func data(
        for url: URL,
        method: String = "GET",
        body: Data? = nil,
        additionalHeaders: [String: String] = [:],
        authentication: ZhihuRequestAuthentication = .accountIfAvailable
    ) async throws -> Data {
        guard ZhihuAPIURLPolicy.allowsAPIRequest(url) else { throw ZhihuAPIError.untrustedURL }
        let credentials = try credentials(authentication: authentication)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        additionalHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")

        if !credentials.cookies.isEmpty {
            request.setValue(
                credentials.cookies.keys.sorted().map { "\($0)=\(credentials.cookies[$0] ?? "")" }.joined(separator: "; "),
                forHTTPHeaderField: "Cookie"
            )
        }
        if let xsrf = credentials.cookies["_xsrf"]?.nonBlank {
            request.setValue(xsrf, forHTTPHeaderField: "x-xsrftoken")
        }
        signer.applySignature(to: &request, cookies: credentials.cookies, body: body)

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              let finalURL = response.url,
              ZhihuAPIURLPolicy.allowsAPIRequest(finalURL)
        else { throw ZhihuAPIError.invalidResponse }
        try persistResponseCookies(response)
        guard (200..<300).contains(response.statusCode) else {
            throw ZhihuAPIError.httpStatus(response.statusCode)
        }
        return data
    }

    private func credentials(authentication: ZhihuRequestAuthentication) throws -> Credentials {
        if case .guest = authentication {
            return Credentials(cookies: [:], userAgent: Self.defaultUserAgent)
        }
        do {
            guard let stored = try ZhihuAccountSessionCodec.credentials(from: accountStore.load()) else {
                if case .accountRequired = authentication { throw ZhihuAPIError.authenticationRequired }
                return Credentials(cookies: [:], userAgent: Self.defaultUserAgent)
            }
            if case .accountRequired = authentication, stored.cookies["d_c0"]?.nonBlank == nil {
                throw ZhihuAPIError.authenticationRequired
            }
            return Credentials(
                cookies: stored.cookies,
                userAgent: stored.userAgent?.nonBlank ?? Self.defaultUserAgent
            )
        } catch let error as ZhihuAPIError {
            throw error
        } catch {
            throw ZhihuAPIError.accountUnavailable
        }
    }

    private func persistResponseCookies(_ response: HTTPURLResponse) throws {
        guard let responseURL = response.url else { return }
        var headerFields: [String: String] = [:]
        response.allHeaderFields.forEach { key, value in
            guard let key = key as? String else { return }
            headerFields[key] = String(describing: value)
        }
        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: responseURL)
        guard !responseCookies.isEmpty else { return }

        do {
            try ZhihuAccountCookieWriter.merge(cookies: responseCookies, into: accountStore)
        } catch let error as ZhihuAPIError {
            throw error
        } catch {
            throw ZhihuAPIError.accountUnavailable
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(
            configuration: configuration,
            delegate: ZhihuRedirectDelegate(),
            delegateQueue: nil
        )
    }

    private struct Credentials {
        let cookies: [String: String]
        let userAgent: String
    }
}

private final class ZhihuRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map { ZhihuAPIURLPolicy.allowsAPIRequest($0) } == true ? request : nil)
    }
}

struct ZhihuAccountCredentials: Equatable {
    let cookies: [String: String]
    let userAgent: String?
}

enum ZhihuAccountSessionCodec {
    static func credentials(from accountJSON: String?) throws -> ZhihuAccountCredentials? {
        guard let accountJSON, let data = accountJSON.data(using: .utf8) else { return nil }
        let stored = try JSONDecoder().decode(StoredAccountSession.self, from: data)
        return ZhihuAccountCredentials(cookies: stored.cookies, userAgent: stored.userAgent)
    }

    static func merging(cookies incoming: [HTTPCookie], into accountJSON: String?) throws -> String? {
        try updatingCookies(in: accountJSON) { cookies in
            for cookie in incoming where ZhihuAPIURLPolicy.allowsCookieDomain(cookie.domain) {
                if cookie.value.isEmpty || cookie.expiresDate.map({ $0 <= Date() }) == true {
                    cookies.removeValue(forKey: cookie.name)
                } else {
                    cookies[cookie.name] = cookie.value
                }
            }
        }
    }

    static func merging(cookieValues incoming: [String: String], into accountJSON: String?) throws -> String? {
        try updatingCookies(in: accountJSON) { cookies in
            for (name, value) in incoming where !name.isEmpty {
                if value.isEmpty {
                    cookies.removeValue(forKey: name)
                } else {
                    cookies[name] = value
                }
            }
        }
    }

    private static func updatingCookies(
        in accountJSON: String?,
        mutation: (inout [String: String]) -> Void
    ) throws -> String? {
        guard let accountJSON,
              let data = accountJSON.data(using: .utf8),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return accountJSON }

        var cookies = root["cookies"] as? [String: String] ?? [:]
        mutation(&cookies)
        root["cookies"] = cookies
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let updatedJSON = String(data: updated, encoding: .utf8) else {
            throw ZhihuAPIError.accountUnavailable
        }
        return updatedJSON
    }

    private struct StoredAccountSession: Decodable {
        let cookies: [String: String]
        let userAgent: String?
    }
}

enum ZhihuAccountCookieWriter {
    static func merge(cookies: [HTTPCookie], into store: AccountJSONStore) throws {
        try store.update { accountJSON in
            try ZhihuAccountSessionCodec.merging(cookies: cookies, into: accountJSON)
        }
    }

    static func merge(cookieValues: [String: String], into store: AccountJSONStore) throws {
        try store.update { accountJSON in
            try ZhihuAccountSessionCodec.merging(cookieValues: cookieValues, into: accountJSON)
        }
    }
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
