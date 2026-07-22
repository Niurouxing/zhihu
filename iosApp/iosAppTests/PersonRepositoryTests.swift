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

    func testProfileAndPageRequireVerifiedAccountBeforeNetworkRequest() async throws {
        let recorder = PersonRequestRecorder()
        PersonRepositoryURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, Data("{}".utf8), [:])
        }
        let repository = makeRepository(accountStore: PersonRepositoryAccountStore(json: nil))
        let identity = PersonIdentity(route: route())

        do {
            _ = try await repository.fetchProfile(identity: identity, provisionalDisplayName: "作者")
            XCTFail("Expected profile loading to require a verified account")
        } catch {
            XCTAssertEqual(error as? ZhihuAPIError, .authenticationRequired)
        }
        do {
            _ = try await repository.fetchPage(
                key: .main(.answers),
                identity: identity,
                sort: .voteups,
                nextURL: nil
            )
            XCTFail("Expected page loading to require a verified account")
        } catch {
            XCTAssertEqual(error as? ZhihuAPIError, .authenticationRequired)
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testProfileAndPageUseVerifiedAccountCookiesAndSignatures() async throws {
        let recorder = PersonRequestRecorder()
        PersonRepositoryURLProtocol.setHandler { request in
            recorder.record(request)
            let body = request.url?.path.hasPrefix("/people/") == true
                ? #"{"id":"member-id","url_token":"token","name":"作者"}"#
                : #"{"data":[],"paging":{"is_end":true,"next":null}}"#
            return (200, Data(body.utf8), [:])
        }
        let account = PersonRepositoryAccountStore(
            json: #"{"cookies":{"d_c0":"device-cookie","z_c0":"login-cookie"},"userAgent":"test-agent"}"#
        )
        let repository = makeRepository(accountStore: account)
        let identity = PersonIdentity(route: route())

        _ = try await repository.fetchProfile(identity: identity, provisionalDisplayName: "作者")
        _ = try await repository.fetchPage(
            key: .main(.answers),
            identity: identity,
            sort: .voteups,
            nextURL: nil
        )

        XCTAssertEqual(recorder.requests.count, 2)
        for request in recorder.requests {
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("d_c0=device-cookie") == true)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("z_c0=login-cookie") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-zse-93"), ZhihuRequestSignature.zse93)
            XCTAssertTrue(request.value(forHTTPHeaderField: "x-zse-96")?.hasPrefix("2.0_") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "test-agent")
        }
    }

    func testPersonRepositoryUsesSharedAtomicResponseCookieMerge() async throws {
        PersonRepositoryURLProtocol.setHandler { _ in
            let body = #"{"data":[],"paging":{"is_end":true,"next":null}}"#
            return (200, Data(body.utf8), ["Set-Cookie": "captcha_session=person; Path=/; Secure"])
        }
        let account = PersonRepositoryAccountStore(
            json: #"{"cookies":{"d_c0":"device-cookie","z_c0":"login-cookie"},"future":"preserved"}"#
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

    func testActivityPageMapsSupportedTargetsToNavigationIntents() async throws {
        PersonRepositoryURLProtocol.setHandler { _ in
            let body = #"""
            {
              "data": [
                {
                  "id": "answer-activity",
                  "action_text": "赞同了回答",
                  "target": {
                    "id": "42",
                    "type": "answer",
                    "excerpt": "回答摘要",
                    "question": { "id": "7", "title": "回答对应的问题" }
                  }
                },
                {
                  "id": "article-activity",
                  "action_text": "赞同了文章",
                  "target": {
                    "id": 8,
                    "type": "article",
                    "title": "动态中的文章",
                    "excerpt": "文章摘要"
                  }
                },
                {
                  "id": "question-activity",
                  "action_text": "关注了问题",
                  "target": { "id": "9", "type": "question", "title": "动态中的问题" }
                },
                {
                  "id": "pin-activity",
                  "action_text": "赞同了想法",
                  "target": { "id": 10, "type": "pin", "excerpt_title": "动态中的想法" }
                },
                {
                  "id": "unknown-activity",
                  "action_text": "关注了话题",
                  "target": { "id": "99", "type": "topic", "name": "未知目标" }
                }
              ],
              "paging": { "is_end": true, "next": null }
            }
            """#
            return (200, Data(body.utf8), [:])
        }
        let repository = makeRepository()

        let result = try await repository.fetchPage(
            key: .main(.activities),
            identity: PersonIdentity(route: route()),
            sort: nil,
            nextURL: nil
        )
        let destinations: [PersonNavigationIntent?] = result.items.map { item in
            guard case let .activity(activity) = item else { return nil }
            return activity.destination
        }

        XCTAssertEqual(destinations, [
            .article(.init(id: 42, kind: .answer)),
            .article(.init(id: 8, kind: .article)),
            .question(9),
            .pin(10),
            nil,
        ])
    }

    func testCollectionPageAcceptsNumericIdentifierFromZhihuAPI() async throws {
        PersonRepositoryURLProtocol.setHandler { _ in
            let body = #"{"data":[{"id":31510489,"title":"实用技巧","answer_count":15,"follower_count":0}],"paging":{"is_end":true,"next":null}}"#
            return (200, Data(body.utf8), [:])
        }
        let repository = makeRepository()

        let result = try await repository.fetchPage(
            key: .main(.collections),
            identity: PersonIdentity(route: route()),
            sort: nil,
            nextURL: nil
        )

        guard case let .collection(collection) = try XCTUnwrap(result.items.first) else {
            return XCTFail("Expected a collection item")
        }
        XCTAssertEqual(collection.collectionID, "31510489")
        XCTAssertEqual(collection.title, "实用技巧")
    }

    func testEverySupportedPageItemTypePreservesItsNavigationIdentifier() async throws {
        PersonRepositoryURLProtocol.setHandler { request in
            let body: String
            switch request.url?.path {
            case "/api/v4/members/token/answers":
                body = #"{"data":[{"id":101,"question":{"id":201,"title":"回答问题"}}],"paging":{"is_end":true,"next":null}}"#
            case "/api/v4/members/token/articles":
                body = #"{"data":[{"id":"102","title":"文章"}],"paging":{"is_end":true,"next":null}}"#
            case "/api/v4/members/token/favlists":
                body = #"{"data":[{"id":"collection-103","title":"收藏夹"}],"paging":{"is_end":true,"next":null}}"#
            case "/api/v4/members/token/questions":
                body = #"{"data":[{"id":"104","title":"问题"}],"paging":{"is_end":true,"next":null}}"#
            case "/api/v4/v2/pins/token/moments":
                body = #"{"data":[{"id":"105","excerpt_title":"想法"}],"paging":{"is_end":true,"next":null}}"#
            case "/api/v4/members/token/column-contributions":
                body = #"{"data":[{"id":"column-106","title":"专栏","url":"http://api.zhihu.com/api/v4/columns/column-106"}],"paging":{"is_end":true,"next":null}}"#
            case "/people/member-id/followers":
                body = #"{"data":[{"id":"member-107","url_token":"person-107","name":"另一个用户"}],"paging":{"is_end":true,"next":null}}"#
            case "/api/v4/members/token/following-topic-contributions":
                body = #"{"data":[{"topic":{"id":"108","name":"话题"}}],"paging":{"is_end":true,"next":null}}"#
            case "/api/v4/members/token/following-questions":
                body = #"{"data":[{"id":"109","title":"关注的问题"}],"paging":{"is_end":true,"next":null}}"#
            default:
                throw PersonRepositoryError.invalidResponse
            }
            return (200, Data(body.utf8), [:])
        }
        let repository = makeRepository()
        let identity = PersonIdentity(route: route())

        let answer = try await firstItem(.main(.answers), identity: identity, repository: repository)
        let article = try await firstItem(.main(.articles), identity: identity, repository: repository)
        let collection = try await firstItem(.main(.collections), identity: identity, repository: repository)
        let question = try await firstItem(.main(.questions), identity: identity, repository: repository)
        let pin = try await firstItem(.main(.pins), identity: identity, repository: repository)
        let column = try await firstItem(.main(.columns), identity: identity, repository: repository)
        let person = try await firstItem(.main(.followers), identity: identity, repository: repository)
        let topic = try await firstItem(.subscription(.followingTopics), identity: identity, repository: repository)
        let followedQuestion = try await firstItem(.subscription(.followingQuestions), identity: identity, repository: repository)

        guard case let .answer(answerValue) = answer else { return XCTFail("Expected answer item") }
        guard case let .article(articleValue) = article else { return XCTFail("Expected article item") }
        guard case let .collection(collectionValue) = collection else { return XCTFail("Expected collection item") }
        guard case let .question(questionValue) = question else { return XCTFail("Expected question item") }
        guard case let .pin(pinValue) = pin else { return XCTFail("Expected pin item") }
        guard case let .column(columnValue) = column else { return XCTFail("Expected column item") }
        guard case let .person(personValue) = person else { return XCTFail("Expected person item") }
        guard case let .topic(topicValue) = topic else { return XCTFail("Expected topic item") }
        guard case let .followedQuestion(followedQuestionValue) = followedQuestion else {
            return XCTFail("Expected followed question item")
        }

        XCTAssertEqual(answerValue.answerID, 101)
        XCTAssertEqual(articleValue.articleID, 102)
        XCTAssertEqual(collectionValue.collectionID, "collection-103")
        XCTAssertEqual(questionValue.questionID, 104)
        XCTAssertEqual(pinValue.pinID, 105)
        XCTAssertEqual(columnValue.destination?.url.absoluteString, "https://api.zhihu.com/column/column-106")
        XCTAssertEqual(personValue.route.urlToken, "person-107")
        XCTAssertEqual(topicValue.destination?.url.absoluteString, "https://www.zhihu.com/topic/108")
        XCTAssertEqual(followedQuestionValue.questionID, 109)
    }

    private func firstItem(
        _ key: PersonPageKey,
        identity: PersonIdentity,
        repository: URLSessionPersonRepository
    ) async throws -> PersonPageItem {
        let result = try await repository.fetchPage(key: key, identity: identity, sort: nil, nextURL: nil)
        return try XCTUnwrap(result.items.first)
    }

    private func makeRepository(
        accountStore: AccountJSONStore = PersonRepositoryAccountStore(
            json: #"{"cookies":{"d_c0":"device-cookie","z_c0":"login-cookie"}}"#
        )
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
    private var storedRequests: [URLRequest] = []

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests.last
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func record(_ request: URLRequest) {
        lock.lock()
        storedRequests.append(request)
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
