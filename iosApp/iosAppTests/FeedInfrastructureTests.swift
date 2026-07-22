import Foundation
import XCTest
@testable import iosApp

final class FeedInfrastructureTests: XCTestCase {
    override func tearDown() {
        FeedURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testHotProjectionOmitsAuthorAndThumbnailAndCreatesAnswerRoute() throws {
        let page = try FeedResponseMapper.page(from: FeedFixtures.hotPage, policy: .hot)
        let item = try XCTUnwrap(page.items.first)

        XCTAssertEqual(item.id, FeedItemID(kind: .answer, contentID: "42"))
        XCTAssertEqual(item.title, "问题标题")
        XCTAssertEqual(item.summary, "回答摘要")
        XCTAssertNil(item.author)
        XCTAssertNil(item.thumbnailURL)
        XCTAssertEqual(
            item.route,
            .answer(answerID: 42, questionID: 7, questionTitle: "问题标题")
        )
        XCTAssertEqual(page.nextURL, URL(string: "https://www.zhihu.com/api/v3/hot?page=2"))
        XCTAssertFalse(page.isEnd)
    }

    func testSearchProjectionKeepsTypedArticlePresentation() throws {
        let page = try FeedResponseMapper.page(from: FeedFixtures.searchPage, policy: .search)
        let item = try XCTUnwrap(page.items.first)

        XCTAssertEqual(item.kind, .article)
        XCTAssertEqual(item.title, "原生搜索文章")
        XCTAssertEqual(item.author?.displayName, "作者")
        XCTAssertEqual(item.thumbnailURL, URL(string: "https://pic.zhimg.com/article.jpg"))
        XCTAssertEqual(item.route, .article(articleID: 81, title: "原生搜索文章"))
    }

    func testSearchProjectionSkipsPromotionalCardWithStructuredDescription() throws {
        let page = try FeedResponseMapper.page(
            from: FeedFixtures.searchPageWithStructuredDescription,
            policy: .search
        )

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.route, .article(articleID: 81, title: "原生搜索文章"))
    }

    func testNonSearchCommercialCardsAreSkippedInsteadOfBecomingNoOpRows() throws {
        let page = try FeedResponseMapper.page(from: FeedFixtures.nonContentSearchPage, policy: .search)
        XCTAssertTrue(page.items.isEmpty)
    }

    func testUntrustedPagingURLRejectsWholePageBeforeItCanReceiveCredentials() throws {
        XCTAssertThrowsError(try FeedResponseMapper.page(from: FeedFixtures.untrustedPagingPage, policy: .hot)) {
            XCTAssertEqual($0 as? ZhihuAPIError, .malformedPayload)
        }
    }

    func testSuggestionsPreserveOrderAndAreCappedAtFifteen() throws {
        let suggestions = try FeedResponseMapper.suggestions(from: FeedFixtures.suggestions)
        XCTAssertEqual(suggestions.count, 15)
        XCTAssertEqual(suggestions.first?.query, "热搜 1")
        XCTAssertEqual(suggestions.last?.query, "热搜 15")
    }

    func testAPIClientAppliesAccountHeadersAndMergesResponseCookie() async throws {
        let recorder = FeedRequestRecorder()
        FeedURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, Data("{}".utf8), ["Set-Cookie": "captcha_session=updated; Path=/; Secure"])
        }
        let account = FeedAccountStore(
            json: #"{"cookies":{"d_c0":"device-cookie","z_c0":"login-cookie","_xsrf":"token"},"userAgent":"feed-agent"}"#
        )
        let client = ZhihuAPIClient(accountStore: account, session: makeFeedSession())

        _ = try await client.data(for: URL(string: "https://www.zhihu.com/api/v4/search/hot_search")!)
        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "feed-agent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-xsrftoken"), "token")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("z_c0=login-cookie") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-zse-93"), ZhihuRequestSignature.zse93)
        XCTAssertTrue(request.value(forHTTPHeaderField: "x-zse-96")?.hasPrefix("2.0_") == true)
        XCTAssertTrue(try XCTUnwrap(account.load()).contains(#""captcha_session":"updated""#))
    }

    func testAccountRequiredRejectsSessionWithoutLoginCookieBeforeNetworkRequest() async throws {
        let recorder = FeedRequestRecorder()
        FeedURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, Data("{}".utf8), [:])
        }
        let account = FeedAccountStore(
            json: #"{"cookies":{"d_c0":"device-cookie"},"userAgent":"feed-agent"}"#
        )
        let client = ZhihuAPIClient(accountStore: account, session: makeFeedSession())

        do {
            _ = try await client.data(
                for: URL(string: "https://www.zhihu.com/api/v4/me")!,
                authentication: .accountRequired
            )
            XCTFail("Expected the incomplete account session to require login")
        } catch {
            XCTAssertEqual(error as? ZhihuAPIError, .authenticationRequired)
        }
        XCTAssertNil(recorder.request)
    }

    func testBlankResponseLoginCookieDoesNotEraseVerifiedSession() throws {
        let blankLoginCookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "z_c0",
                .value: "",
                .domain: ".zhihu.com",
                .path: "/",
            ])
        )
        let source = #"{"login":true,"cookies":{"d_c0":"device-cookie","z_c0":"login-cookie"},"future":7}"#

        let merged = try XCTUnwrap(
            ZhihuAccountSessionCodec.merging(cookies: [blankLoginCookie], into: source)
        )
        let credentials = try XCTUnwrap(ZhihuAccountSessionCodec.credentials(from: merged))

        XCTAssertEqual(credentials.cookies["z_c0"], "login-cookie")
        XCTAssertEqual(credentials.cookies["d_c0"], "device-cookie")
        XCTAssertTrue(merged.contains(#""future":7"#))
    }

    func testAPIClientKeepsLoginCookieWhenSuccessfulResponseAttemptsToClearIt() async throws {
        FeedURLProtocol.setHandler { _ in
            (
                200,
                Data("{}".utf8),
                ["Set-Cookie": "z_c0=; Max-Age=0; Path=/; Secure"]
            )
        }
        let account = FeedAccountStore(
            json: #"{"login":true,"cookies":{"d_c0":"device-cookie","z_c0":"login-cookie"},"userAgent":"feed-agent"}"#
        )
        let client = ZhihuAPIClient(accountStore: account, session: makeFeedSession())

        _ = try await client.data(
            for: URL(string: "https://www.zhihu.com/api/v4/me")!,
            authentication: .accountRequired
        )
        let credentials = try XCTUnwrap(
            ZhihuAccountSessionCodec.credentials(from: account.load())
        )

        XCTAssertEqual(credentials.cookies["z_c0"], "login-cookie")
        XCTAssertEqual(credentials.cookies["d_c0"], "device-cookie")
    }

    func testAccountSessionCodecPreservesQuotedDeviceCookieRepresentation() throws {
        let account = [
            "cookies": [
                "d_c0": #""quoted-device-cookie""#,
                "z_c0": "login-cookie",
            ],
            "userAgent": "feed-agent",
        ] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: account, options: [.sortedKeys])
        let credentials = try XCTUnwrap(
            ZhihuAccountSessionCodec.credentials(from: String(decoding: data, as: UTF8.self))
        )
        let deviceCookie = try XCTUnwrap(credentials.cookies["d_c0"])

        XCTAssertEqual(Set(credentials.cookies.keys), ["d_c0", "z_c0"])
        XCTAssertTrue(deviceCookie.hasPrefix("\""))
        XCTAssertTrue(deviceCookie.hasSuffix("\""))
        XCTAssertEqual(deviceCookie.count, 22)
    }

    func testSearchRepositoryBuildsExistingFilterAndMemberRestrictionContract() async throws {
        let recorder = FeedRequestRecorder()
        FeedURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, FeedFixtures.emptyPage, [:])
        }
        let repository = URLSessionSearchRepository(
            accountStore: FeedAccountStore(
                json: #"{"cookies":{"d_c0":"device-cookie","z_c0":"login-cookie"},"userAgent":"feed-agent"}"#
            ),
            session: makeFeedSession()
        )
        let criteria = SearchCriteria(
            query: "知乎 搜索/排序",
            restrictedMemberHashID: "member hash/id",
            sort: .latest,
            contentType: .answer,
            timeRange: .week
        )

        _ = try await repository.fetchPage(criteria: criteria, after: nil)
        let url = try XCTUnwrap(recorder.request?.url?.absoluteString)
        XCTAssertTrue(url.contains("q=%E7%9F%A5%E4%B9%8E+%E6%90%9C%E7%B4%A2%2F%E6%8E%92%E5%BA%8F"))
        XCTAssertTrue(url.contains("restricted_scene=member"))
        XCTAssertTrue(url.contains("restricted_field=member_hash_id"))
        XCTAssertTrue(url.contains("restricted_value=member+hash%2Fid"))
        XCTAssertTrue(url.contains("sort=created_time"))
        XCTAssertTrue(url.contains("vertical=answer"))
        XCTAssertTrue(url.contains("time_interval=a_week"))
        XCTAssertTrue(url.contains("include="))
        let request = try XCTUnwrap(recorder.request)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("z_c0=login-cookie") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-zse-93"), ZhihuRequestSignature.zse93)
        XCTAssertTrue(request.value(forHTTPHeaderField: "x-zse-96")?.hasPrefix("2.0_") == true)
    }

    func testSearchSuggestionsUseAuthenticatedSignature() async throws {
        let recorder = FeedRequestRecorder()
        FeedURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, FeedFixtures.suggestions, [:])
        }
        let repository = URLSessionSearchRepository(
            accountStore: FeedAccountStore(
                json: #"{"cookies":{"d_c0":"device-cookie","z_c0":"login-cookie"},"userAgent":"feed-agent"}"#
            ),
            session: makeFeedSession()
        )

        let suggestions = try await repository.fetchSuggestions()

        XCTAssertEqual(suggestions.count, 15)
        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.url?.path, "/api/v4/search/hot_search")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("z_c0=login-cookie") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-zse-93"), ZhihuRequestSignature.zse93)
        XCTAssertTrue(request.value(forHTTPHeaderField: "x-zse-96")?.hasPrefix("2.0_") == true)
    }

    func testSearchRepositoryRejectsMissingAccountBeforeNetworkRequest() async {
        let recorder = FeedRequestRecorder()
        FeedURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, FeedFixtures.emptyPage, [:])
        }
        let repository = URLSessionSearchRepository(
            accountStore: FeedAccountStore(json: nil),
            session: makeFeedSession()
        )

        do {
            _ = try await repository.fetchSuggestions()
            XCTFail("Expected search suggestion authentication failure")
        } catch {
            XCTAssertEqual(error as? ZhihuAPIError, .authenticationRequired)
        }
        do {
            _ = try await repository.fetchPage(
                criteria: SearchCriteria(
                    query: "Swift",
                    restrictedMemberHashID: nil,
                    sort: .relevance,
                    contentType: .all,
                    timeRange: .all
                ),
                after: nil
            )
            XCTFail("Expected search result authentication failure")
        } catch {
            XCTAssertEqual(error as? ZhihuAPIError, .authenticationRequired)
        }

        XCTAssertNil(recorder.request)
    }

    func testAPIRequestPolicyUsesKnownHostAndPathPairs() throws {
        XCTAssertTrue(
            ZhihuAPIURLPolicy.allowsAPIRequest(
                try XCTUnwrap(URL(string: "https://www.zhihu.com/api/v4/search/hot_search"))
            )
        )
        XCTAssertTrue(
            ZhihuAPIURLPolicy.allowsAPIRequest(
                try XCTUnwrap(URL(string: "https://api.zhihu.com/notifications/v3/message/v3"))
            )
        )
        XCTAssertTrue(
            ZhihuAPIURLPolicy.allowsAPIRequest(
                try XCTUnwrap(URL(string: "https://api.zhihu.com/search_v3?offset=20"))
            )
        )
        XCTAssertTrue(
            ZhihuAPIURLPolicy.allowsAPIRequest(
                try XCTUnwrap(URL(string: "https://news-at.zhihu.com/api/4/stories/latest"))
            )
        )
        XCTAssertFalse(
            ZhihuAPIURLPolicy.allowsAPIRequest(
                try XCTUnwrap(URL(string: "https://www.zhihu.com/question/7"))
            )
        )
        XCTAssertFalse(
            ZhihuAPIURLPolicy.allowsAPIRequest(
                try XCTUnwrap(URL(string: "https://unknown.zhihu.com/api/v4/steal"))
            )
        )
        XCTAssertFalse(
            ZhihuAPIURLPolicy.allowsAPIRequest(
                try XCTUnwrap(URL(string: "https://api.zhihu.com/search_v4?offset=20"))
            )
        )
        XCTAssertFalse(
            ZhihuAPIURLPolicy.allows(
                try XCTUnwrap(URL(string: "https://user:password@www.zhihu.com/api/v4/me"))
            )
        )
    }

    func testAccountSessionCookieMergePreservesUnknownFieldsAndRejectsForeignDomains() throws {
        let trusted = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "captcha_session",
                .value: "updated",
                .domain: ".zhihu.com",
                .path: "/",
            ])
        )
        let foreign = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "foreign",
                .value: "ignored",
                .domain: ".example.com",
                .path: "/",
            ])
        )
        let source = #"{"cookies":{"z_c0":"token"},"userAgent":"agent","future":{"value":1}}"#

        let merged = try XCTUnwrap(
            ZhihuAccountSessionCodec.merging(cookies: [trusted, foreign], into: source)
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any]
        )
        let cookies = try XCTUnwrap(root["cookies"] as? [String: String])
        XCTAssertEqual(cookies["z_c0"], "token")
        XCTAssertEqual(cookies["captcha_session"], "updated")
        XCTAssertNil(cookies["foreign"])
        XCTAssertNotNil(root["future"])
    }
}

private enum FeedFixtures {
    static let hotPage = Data(
        #"{"data":[{"type":"hot_list_feed","detail_text":"热度 100 万","target":{"id":42,"type":"answer","url":"https://api.zhihu.com/answers/42","excerpt":"回答摘要","voteup_count":475,"comment_count":138,"thumbnail":"https://pic.zhimg.com/answer.jpg","question":{"id":7,"type":"question","title":"问题标题"},"author":{"id":"member","url_token":"author","name":"作者","headline":"简介","avatar_url":"https://pic.zhimg.com/avatar.jpg"}}}],"paging":{"is_end":false,"next":"http://www.zhihu.com/api/v3/hot?page=2"}}"#.utf8
    )

    static let searchPage = Data(
        #"{"data":[{"type":"search_result","id":"result-1","object":{"id":"81","type":"article","title":"原生搜索文章","excerpt":"文章摘要","voteup_count":12,"comment_count":3,"thumbnail_info":{"thumbnails":[{"url":"https://pic.zhimg.com/article.jpg"}]},"author":{"id":"member","url_token":"author","name":"作者","headline":"简介","avatar_url":"https://pic.zhimg.com/avatar.jpg"}}}],"paging":{"is_end":true,"next":null}}"#.utf8
    )

    static let searchPageWithStructuredDescription = Data(
        #"{"data":[{"type":"hot_timing","object":{"type":"hot_timing","title":"热点聚合","description":{"type":"question","object":{"id":"9","type":"question","title":"聚合问题"}}}},{"type":"search_result","id":"result-1","object":{"id":"81","type":"article","title":"原生搜索文章","excerpt":"文章摘要","voteup_count":12,"comment_count":3,"thumbnail_info":{"thumbnails":[{"url":"https://pic.zhimg.com/article.jpg"}]},"author":{"id":"member","url_token":"author","name":"作者","headline":"简介","avatar_url":"https://pic.zhimg.com/avatar.jpg"}}}],"paging":{"is_end":true,"next":null}}"#.utf8
    )

    static let nonContentSearchPage = Data(
        #"{"data":[{"type":"knowledge_ad","object":{"id":"1","type":"paid_column","title":"广告"}}],"paging":{"is_end":true,"next":null}}"#.utf8
    )

    static let untrustedPagingPage = Data(
        #"{"data":[],"paging":{"is_end":false,"next":"https://attacker.example/steal"}}"#.utf8
    )

    static let emptyPage = Data(#"{"data":[],"paging":{"is_end":true,"next":null}}"#.utf8)

    static let suggestions: Data = {
        let rows = (1...18).map { #"{"query":"热搜 \#($0)","hot_show":"\#($0) 万"}"# }.joined(separator: ",")
        return Data(#"{"hot_search_queries":[\#(rows)]}"#.utf8)
    }()
}

private func makeFeedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FeedURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class FeedURLProtocol: URLProtocol {
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
            client?.urlProtocol(self, didFailWithError: ZhihuAPIError.invalidResponse)
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

    override func stopLoading() {}
}

private final class FeedRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    func record(_ request: URLRequest) {
        let captured = URLRequestBodyCapture.capture(request)
        lock.lock()
        storedRequest = captured
        lock.unlock()
    }
}

enum URLRequestBodyCapture {
    static func capture(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                body.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                var captured = request
                captured.httpBodyStream = nil
                captured.httpBody = body
                return captured
            } else {
                return request
            }
        }
    }
}

private final class FeedAccountStore: AccountJSONStore, @unchecked Sendable {
    private let lock = NSLock()
    private var json: String?

    init(json: String?) { self.json = json }

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
