import Foundation

enum LoginCompletionMatcher {
    static func matches(pageURL: URL?, completionURL: String) -> Bool {
        pageURL?.absoluteString == completionURL
    }
}

struct LoginSubmissionGate {
    private var isActive = false
    private var submissionID: UUID?

    var hasSubmission: Bool { submissionID != nil }
    var allowsUserDismissal: Bool { submissionID == nil }

    mutating func activate() {
        isActive = true
    }

    mutating func beginSubmission() -> UUID? {
        guard isActive, submissionID == nil else { return nil }
        let id = UUID()
        submissionID = id
        return id
    }

    func accepts(_ id: UUID) -> Bool {
        isActive && submissionID == id
    }

    mutating func finish(_ id: UUID) -> Bool {
        guard accepts(id) else { return false }
        submissionID = nil
        return true
    }

    mutating func cancelByUser() -> Bool {
        guard allowsUserDismissal else { return false }
        deactivate()
        return true
    }

    mutating func deactivate() {
        isActive = false
        submissionID = nil
    }
}

enum RiskControlCookieCodec {
    enum PayloadError: Error {
        case invalidJSON
        case invalidCookie(String)
    }

    static func cookieValues(from cookiesJSON: String) throws -> [String: String] {
        guard let data = cookiesJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PayloadError.invalidJSON
        }

        var values: [String: String] = [:]
        for (name, value) in object {
            guard let value = value as? String else {
                throw PayloadError.invalidJSON
            }
            values[name] = value
        }
        return values
    }

    static func cookiesForInjection(cookiesJSON: String, pageURL: URL) throws -> [HTTPCookie] {
        let values = try cookieValues(from: cookiesJSON)
        return try values.keys.sorted().map { name in
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: values[name] ?? "",
                .domain: ".zhihu.com",
                .path: "/",
                .originURL: URL(string: "https://www.zhihu.com/")!,
            ]
            if pageURL.scheme?.lowercased() == "https" {
                properties[.secure] = "TRUE"
            }
            guard let cookie = HTTPCookie(properties: properties) else {
                throw PayloadError.invalidCookie(name)
            }
            return cookie
        }
    }
}

enum ZhihuCookieCollector {
    static func jsonString(from cookies: [HTTPCookie], for homeURL: URL) throws -> String {
        let values = cookieValues(from: cookies, for: homeURL)
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return json
    }

    static func cookieValues(from cookies: [HTTPCookie], for url: URL) -> [String: String] {
        var selected: [String: HTTPCookie] = [:]
        for cookie in cookies where !cookie.value.isEmpty && applies(cookie, to: url) {
            guard let current = selected[cookie.name] else {
                selected[cookie.name] = cookie
                continue
            }
            if isMoreSpecific(cookie, than: current) {
                selected[cookie.name] = cookie
            }
        }
        return selected.mapValues(\.value)
    }

    private static func applies(_ cookie: HTTPCookie, to url: URL) -> Bool {
        guard let requestHost = url.host?.lowercased() else { return false }
        let cookieDomain = normalizedDomain(cookie)
        guard cookieDomain == "zhihu.com" || cookieDomain.hasSuffix(".zhihu.com") else {
            return false
        }
        guard requestHost == cookieDomain || requestHost.hasSuffix(".\(cookieDomain)") else {
            return false
        }
        if cookie.isSecure && url.scheme?.lowercased() != "https" {
            return false
        }

        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = normalizedPath(cookie)
        if requestPath == cookiePath {
            return true
        }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath.hasSuffix("/") {
            return true
        }
        let boundary = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return boundary < requestPath.endIndex && requestPath[boundary] == "/"
    }

    private static func isMoreSpecific(_ lhs: HTTPCookie, than rhs: HTTPCookie) -> Bool {
        let lhsPath = normalizedPath(lhs)
        let rhsPath = normalizedPath(rhs)
        if lhsPath.count != rhsPath.count { return lhsPath.count > rhsPath.count }

        let lhsDomain = normalizedDomain(lhs)
        let rhsDomain = normalizedDomain(rhs)
        if lhsDomain.count != rhsDomain.count { return lhsDomain.count > rhsDomain.count }
        if lhsPath != rhsPath { return lhsPath > rhsPath }
        if lhsDomain != rhsDomain { return lhsDomain > rhsDomain }
        if lhs.domain != rhs.domain { return lhs.domain > rhs.domain }
        if lhs.isSecure != rhs.isSecure { return lhs.isSecure }
        return lhs.value > rhs.value
    }

    private static func normalizedDomain(_ cookie: HTTPCookie) -> String {
        cookie.domain.drop(while: { $0 == "." }).lowercased()
    }

    private static func normalizedPath(_ cookie: HTTPCookie) -> String {
        cookie.path.hasPrefix("/") && !cookie.path.isEmpty ? cookie.path : "/"
    }
}
