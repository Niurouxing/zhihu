import Foundation
import XCTest
@testable import iosApp

final class PersonRepositoryTests: XCTestCase {
    override func tearDown() {
        PersonRepositoryURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testPagingNextRejectsNonZhihuHostBeforeItCanReceiveCookies() async throws {
        PersonRepositoryURLProtocol.setHandler { request in
            let body = #"{"data":[],"paging":{"is_end":false,"next":"https://attacker.example/api/v4/next"}}"#
            return (200, Data(body.utf8), [:])
        }
        let repository = makeRepository()

        do {
            _ = try await repository.fetchPage(
                key: .main(.answers),
                identity: PersonIdentity(route: route()),
                sort: .voteups,
                nextURL: nil
            )
            XCTFail("Expected the untrusted paging URL to be rejected")
        } catch PersonRepositoryError.malformedPayload {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPagingNextAcceptsExpectedZhihuAPIPath() async throws {
        PersonRepositoryURLProtocol.setHandler { request in
            let body = #"{"data":[],"paging":{"is_end":false,"next":"http://www.zhihu.com/api/v4/members/token/answers?page=2"}}"#
            return (200, Data(body.utf8), [:])
        }
        let repository = makeRepository()

        let result = try await repository.fetchPage(
            key: .main(.answers),
            identity: PersonIdentity(route: route()),
            sort: .voteups,
            nextURL: nil
        )

        XCTAssertEqual(
            result.nextURL,
            URL(string: "https://www.zhihu.com/api/v4/members/token/answers?page=2")
        )
    }

    func testSignedRequestContainsSortIncludeCookieAndZSEHeaders() async throws {
        let recorder = PersonRequestRecorder()
        PersonRepositoryURLProtocol.setHandler { request in
            recorder.record(request)
            let body = #"{"data":[],"paging":{"is_end":true,"next":null}}"#
            return (200, Data(body.utf8), [:])
        }
        let account = PersonRepositoryAccountStore(
            json: #"{"cookies":{"d_c0":"device-cookie","z_c0":"login-cookie"},"userAgent":"test-agent"}"#
        )
        let repository = makeRepository(accountStore: account)

        _ = try await repository.fetchPage(
            key: .main(.answers),
            identity: PersonIdentity(route: route()),
            sort: .created,
            nextURL: nil
        )
        let request = try XCTUnwrap(recorder.request)

        XCTAssertTrue(request.url?.absoluteString.contains("sort_by=created") == true)
        XCTAssertTrue(request.url?.absoluteString.contains("include=") == true)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("z_c0=login-cookie") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-zse-93"), ZhihuRequestSignature.zse93)
        XCTAssertTrue(request.value(forHTTPHeaderField: "x-zse-96")?.hasPrefix("2.0_") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "test-agent")
    }

    func testPersonRepositoryUsesSharedAtomicResponseCookieMerge() async throws {
        PersonRepositoryURLProtocol.setHandler { _ in
            let body = #"{"data":[],"paging":{"is_end":true,"next":null}}"#
            return (200, Data(body.utf8), ["Set-Cookie": "captcha_session=person; Path=/; Secure"])
        }
        let account = PersonRepositoryAccountStore(
            json: #"{"cookies":{"d_c0":"device-cookie"},"future":"preserved"}"#
        )
        let repository = makeRepository(accountStore: account)

        _ = try await repository.fetchPage(
            key: .main(.answers),
            identity: PersonIdentity(route: route()),
            sort: .voteups,
            nextURL: nil
        )

        let updated = try XCTUnwrap(account.load())
        XCTAssertTrue(updated.contains(#""captcha_session":"person""#))
        XCTAssertTrue(updated.contains(#""future":"preserved""#))
    }

    private func makeRepository(
        accountStore: AccountJSONStore = PersonRepositoryAccountStore(json: nil)
    ) -> URLSessionPersonRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PersonRepositoryURLProtocol.self]
        return URLSessionPersonRepository(
            accountStore: accountStore,
            session: URLSession(configuration: configuration)
        )
    }

    private func route() -> PersonRoutePayload {
        PersonRoutePayload(
            memberID: "member-id",
            urlToken: "token",
            displayName: "作者"
        )!
    }
}

private final class PersonRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    func record(_ request: URLRequest) {
        lock.lock()
        storedRequest = request
        lock.unlock()
    }
}

private final class PersonRepositoryURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])

    private static let lock = NSLock()
    private static var storedHandler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.lock()
        storedHandler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.storedHandler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: PersonRepositoryError.invalidResponse)
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
    }
}

private final class PersonRepositoryAccountStore: AccountJSONStore, @unchecked Sendable {
    private let lock = NSLock()
    private var json: String?

    init(json: String?) {
        self.json = json
    }

    func load() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return json
    }

    func save(_ accountJSON: String) throws {
        lock.lock()
        json = accountJSON
        lock.unlock()
    }

    func clear() throws {
        lock.lock()
        json = nil
        lock.unlock()
    }

    func update(_ transform: (String?) throws -> String?) throws {
        lock.lock()
        defer { lock.unlock() }
        json = try transform(json)
    }
}
