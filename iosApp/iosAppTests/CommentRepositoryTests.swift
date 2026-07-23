import Foundation
import XCTest
@testable import iosApp

final class CommentRepositoryTests: XCTestCase {
    override func tearDown() {
        CommentURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testMediaProjectionPreservesAllKnownMediaInSourceOrderAndRemovesThemFromTextHTML() throws {
        let html = """
        <p>正文</p>
        <a class="comment_img" href="https://pic.zhimg.com/1.jpg">image</a>
        <a href="https://pic.zhimg.com/2.gif" class="comment_gif extra">gif</a>
        <a class='comment_sticker' href='https://pic.zhimg.com/3.png'>sticker</a>
        """

        let projection = CommentHTMLMediaParser.project(html)

        XCTAssertEqual(projection.media.map(\.kind), [.image, .animatedImage, .sticker])
        XCTAssertEqual(projection.media.map(\.url.absoluteString), [
            "https://pic.zhimg.com/1.jpg",
            "https://pic.zhimg.com/2.gif",
            "https://pic.zhimg.com/3.png",
        ])
        XCTAssertTrue(projection.textHTML.contains("正文"))
        XCTAssertFalse(projection.textHTML.contains("comment_img"))
        XCTAssertFalse(projection.textHTML.contains("comment_gif"))
        XCTAssertFalse(projection.textHTML.contains("comment_sticker"))
    }

    func testUntrustedPagingURLIsRejectedBeforeReceivingAnotherRequest() async throws {
        let requests = CommentRequestRecorder()
        CommentURLProtocol.setHandler { request in
            requests.record(request)
            let body = Self.pageJSON(
                next: "https://attacker.example/api/v4/comment_v5/answers/1/root_comment?page=2"
            )
            return (200, Data(body.utf8), [:])
        }
        let repository = makeRepository()

        do {
            _ = try await repository.fetchPage(
                route: CommentThreadRouteDTO(subject: .answer(1)),
                level: .root,
                sort: .score,
                nextURL: nil
            )
            XCTFail("Expected untrusted continuation rejection")
        } catch CommentRepositoryError.untrustedContinuation {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(requests.requests.count, 1)
    }

    func testRootRequestUsesScoreAndAccountAuthentication() async throws {
        let requests = CommentRequestRecorder()
        CommentURLProtocol.setHandler { request in
            requests.record(request)
            return (200, Data(Self.pageJSON(next: nil).utf8), [:])
        }
        let repository = makeRepository()

        _ = try await repository.fetchPage(
            route: CommentThreadRouteDTO(subject: .answer(42)),
            level: .root,
            sort: .score,
            nextURL: nil
        )
        let request = try XCTUnwrap(requests.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v4/comment_v5/answers/42/root_comment")
        XCTAssertTrue(request.url?.query?.contains("order_by=score") == true)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("z_c0=login-cookie") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-zse-93"), ZhihuRequestSignature.zse93)
    }

    func testRootContinuationUsesSelectedSortInsteadOfStalePagingSort() async throws {
        let requests = CommentRequestRecorder()
        CommentURLProtocol.setHandler { request in
            requests.record(request)
            return (200, Data(Self.pageJSON(next: nil).utf8), [:])
        }
        let repository = makeRepository()
        let nextURL = try XCTUnwrap(
            URL(string: "https://www.zhihu.com/api/v4/comment_v5/answers/42/root_comment?offset=cursor&order_by=score")
        )

        _ = try await repository.fetchPage(
            route: CommentThreadRouteDTO(subject: .answer(42)),
            level: .root,
            sort: .time,
            nextURL: nextURL
        )

        let queryItems = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(requests.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(queryItems.filter { $0.name == "order_by" }.map(\.value), ["ts"])
        XCTAssertEqual(queryItems.first(where: { $0.name == "offset" })?.value, "cursor")
    }

    func testInlineReplyInitialRequestUsesFiveItemPage() async throws {
        let requests = CommentRequestRecorder()
        CommentURLProtocol.setHandler { request in
            requests.record(request)
            return (200, Data(Self.pageJSON(next: nil).utf8), [:])
        }
        let repository = makeRepository()

        _ = try await repository.fetchPage(
            route: CommentThreadRouteDTO(subject: .answer(42)),
            level: .replies(rootCommentID: "root"),
            sort: .score,
            nextURL: nil
        )

        let request = try XCTUnwrap(requests.requests.first)
        let queryItems = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(queryItems.filter { $0.name == "limit" }.map(\.value), ["5"])
    }

    func testInlineReplyContinuationOverridesPageSizeAndPreservesCursor() async throws {
        let requests = CommentRequestRecorder()
        CommentURLProtocol.setHandler { request in
            requests.record(request)
            return (200, Data(Self.pageJSON(next: nil).utf8), [:])
        }
        let repository = makeRepository()
        let nextURL = try XCTUnwrap(
            URL(string: "https://www.zhihu.com/api/v4/comment_v5/comment/root/child_comment?limit=20&offset=cursor")
        )

        _ = try await repository.fetchPage(
            route: CommentThreadRouteDTO(subject: .answer(42)),
            level: .replies(rootCommentID: "root"),
            sort: .score,
            nextURL: nextURL
        )

        let request = try XCTUnwrap(requests.requests.first)
        let queryItems = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(queryItems.filter { $0.name == "limit" }.map(\.value), ["5"])
        XCTAssertEqual(queryItems.first(where: { $0.name == "offset" })?.value, "cursor")
    }

    func testSubmitEscapesAllFiveHTMLCharactersAndUsesReplyTarget() async throws {
        let requests = CommentRequestRecorder()
        CommentURLProtocol.setHandler { request in
            requests.record(request)
            return (200, Data(Self.commentJSON(id: "submitted").utf8), [:])
        }
        let repository = makeRepository()
        let snapshot = CommentSubmissionSnapshotDTO(
            operationID: 1,
            acceptanceKey: CommentPageAcceptanceKey(
                sessionID: CommentSessionID(),
                level: .replies(rootCommentID: "root"),
                generation: 0
            ),
            subject: .answer(42),
            level: .replies(rootCommentID: "root"),
            text: "<&>\"'",
            imageData: nil,
            replyToCommentID: "child"
        )

        _ = try await repository.submit(snapshot)
        let body = try XCTUnwrap(requests.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["content"], "<p>&lt;&amp;&gt;&quot;&#39;</p>")
        XCTAssertEqual(json["reply_comment_id"], "child")
    }

    func testCommentSubmissionHTMLIncludesUploadedImageAnchor() throws {
        let url = try XCTUnwrap(URL(string: "https://pic.zhimg.com/comment.jpg?a=1&b=2"))

        XCTAssertEqual(
            CommentSubmissionHTML.make(text: "正文", imageURL: url),
            #"<p>正文</p><a class="comment_img" href="https://pic.zhimg.com/comment.jpg?a=1&amp;b=2">[图片]</a>"#
        )
    }

    func testCommentEmojiCatalogRendersKnownPlaceholdersAndKeepsUnknownText() {
        XCTAssertEqual(CommentEmojiCatalog.renderedText("你好[微笑][吃瓜]"), "你好😊🍉")
        XCTAssertEqual(CommentEmojiCatalog.renderedText("[未知]"), "[未知]")
    }

    private func makeRepository() -> URLSessionCommentRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommentURLProtocol.self]
        let accountStore = CommentAccountStore(
            json: #"{"cookies":{"d_c0":"device-cookie","z_c0":"login-cookie"},"userAgent":"comment-test"}"#
        )
        let client = ZhihuAPIClient(
            accountStore: accountStore,
            session: URLSession(configuration: configuration)
        )
        return URLSessionCommentRepository(client: client)
    }

    private static func pageJSON(next: String?) -> String {
        let nextJSON = next.map { "\"\($0)\"" } ?? "null"
        return #"{"data":["# + commentJSON(id: "root") + #"],"paging":{"is_end":false,"next":"# + nextJSON + "}}"
    }

    private static func commentJSON(id: String) -> String {
        """
        {"id":"\(id)","content":"<p>comment</p>","created_time":1,
         "author":{"id":"member","url_token":"token","name":"作者","avatar_url":"https://pic.zhimg.com/avatar.jpg"},
         "reply_to_author":null,"liked":false,"like_count":2,"child_comment_count":0,"child_comments":[]}
        """
    }
}

private final class CommentRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ request: URLRequest) {
        let captured = URLRequestBodyCapture.capture(request)
        lock.lock()
        stored.append(captured)
        lock.unlock()
    }
}

private final class CommentURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])
    private static let lock = NSLock()
    private static var handler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: CommentRepositoryError.malformedPayload)
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

private final class CommentAccountStore: AccountJSONStore, @unchecked Sendable {
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
