import Foundation
import XCTest
@testable import iosApp

final class CreationContractTests: XCTestCase {
    override func tearDown() {
        CreationURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testPlainTextCompilerEscapesMarkupAndPreservesParagraphs() {
        XCTAssertEqual(
            CreationHTMLCompiler.html(from: "一 < 二\n换行\n\n第二段"),
            "<p>一 &lt; 二<br>换行</p><p>第二段</p>"
        )
    }

    func testPublishResponseParsesNestedPublishID() throws {
        let data = Data(#"{"message":"success","data":{"result":"{\"publish\":{\"id\":\"42\"}}"}}"#.utf8)
        XCTAssertEqual(try CreationResponseMapper.publishedID(from: data), 42)
    }

    func testDeletedExistingAnswerIsTreatedAsNewAnswer() throws {
        let data = Data(#"{"relationship":{"my_answer":{"answer_id":"42","is_deleted":true}}}"#.utf8)
        XCTAssertNil(try CreationResponseMapper.myAnswerID(from: data))
    }

    func testRiskAndLoginErrorsProduceNativeSystemIntents() {
        XCTAssertEqual(CreationError.loginRequired.systemIntent, .loginRequired)
        XCTAssertEqual(
            CreationError.riskControlRequired.systemIntent,
            .riskControlRequired(URL(string: "https://www.zhihu.com/account/risk_control/")!)
        )
    }

    func testPinDraftUsesObservedActionAndHybridPayload() async throws {
        let recorder = CreationRequestRecorder()
        CreationURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, Data("{}".utf8))
        }
        let client = ZhihuAPIClient(
            accountStore: CreationAccountStore(),
            session: makeCreationSession()
        )
        let repository = URLSessionCreationRepository(client: client)

        try await repository.savePinDraft(title: "标题", text: "正文")

        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.zhihu.com/content/drafts")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(request.httpBody)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(root["action"] as? String, "pin")
        let payload = try XCTUnwrap(root["data"] as? [String: Any])
        XCTAssertEqual((payload["title"] as? [String: Any])?["title"] as? String, "标题")
        XCTAssertEqual((payload["hybrid"] as? [String: Any])?["html"] as? String, "<p>正文</p>")
    }

    func testForbiddenCreationRequestEmitsRiskControlFailure() async {
        CreationURLProtocol.setHandler { _ in (403, Data("{}".utf8)) }
        let repository = URLSessionCreationRepository(
            client: ZhihuAPIClient(accountStore: CreationAccountStore(), session: makeCreationSession())
        )

        do {
            try await repository.savePinDraft(title: "", text: "正文")
            XCTFail("Expected risk-control error")
        } catch {
            XCTAssertEqual(error as? CreationError, .riskControlRequired)
        }
    }
}

@MainActor
final class CreationStoreTests: XCTestCase {
    func testAnswerPublishFailureRetainsDraftAndEmitsLoginIntent() async {
        let repository = CreationRepositoryStub(answerPublish: .failure(CreationError.loginRequired))
        let store = WriteAnswerNativeStore(
            route: WriteAnswerRouteDTO(questionID: 7, questionTitle: "问题"),
            repository: repository
        )
        store.text = "不能丢失的回答"

        let result = await store.publish()

        XCTAssertNil(result)
        XCTAssertEqual(store.text, "不能丢失的回答")
        XCTAssertEqual(store.systemIntent, .loginRequired)
    }

    func testPinSaveFailureRetainsTitleAndText() async {
        let repository = CreationRepositoryStub(pinSave: .failure(CreationError.requestFailed("网络失败")))
        let store = WritePinNativeStore(repository: repository)
        store.title = "标题"
        store.text = "正文"

        let saved = await store.saveDraft()
        XCTAssertFalse(saved)
        XCTAssertEqual(store.title, "标题")
        XCTAssertEqual(store.text, "正文")
        XCTAssertEqual(store.errorMessage, "网络失败")
    }

    func testUnchangedExistingAnswerPublishesOriginalRichHTML() async {
        let originalHTML = #"<p><strong>保留加粗</strong><a href="https://www.zhihu.com/question/1">链接</a></p>"#
        let repository = CreationRepositoryStub(
            existingAnswer: ExistingAnswerDraftDTO(
                answerID: 42,
                text: "保留加粗链接",
                originalHTML: originalHTML,
                tableOfContentsEnabled: false
            )
        )
        let store = WriteAnswerNativeStore(
            route: WriteAnswerRouteDTO(questionID: 7, questionTitle: "问题"),
            repository: repository
        )

        await store.loadExistingIfNeeded()
        _ = await store.publish()

        let publishedHTML = await repository.lastPublishedHTML()
        XCTAssertEqual(publishedHTML, originalHTML)
    }
}

private actor CreationRepositoryStub: CreationRepository {
    let answerPublish: Result<Int64, Error>
    let pinSave: Result<Void, Error>
    let existingAnswer: ExistingAnswerDraftDTO?
    private var publishedHTML: String?

    init(
        answerPublish: Result<Int64, Error> = .success(42),
        pinSave: Result<Void, Error> = .success(()),
        existingAnswer: ExistingAnswerDraftDTO? = nil
    ) {
        self.answerPublish = answerPublish
        self.pinSave = pinSave
        self.existingAnswer = existingAnswer
    }

    func fetchExistingAnswer(questionID: Int64) async throws -> ExistingAnswerDraftDTO? { existingAnswer }

    func saveAnswerDraft(
        questionID: Int64,
        answerID: Int64?,
        html: String,
        tableOfContentsEnabled: Bool
    ) async throws {}

    func publishAnswer(
        questionID: Int64,
        answerID: Int64?,
        html: String,
        tableOfContentsEnabled: Bool
    ) async throws -> Int64 {
        publishedHTML = html
        return try answerPublish.get()
    }

    func savePinDraft(title: String, text: String) async throws { try pinSave.get() }
    func publishPin(title: String, text: String) async throws -> Int64 { 12 }
    func lastPublishedHTML() -> String? { publishedHTML }
}

private func makeCreationSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CreationURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class CreationURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
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
        guard let handler else { return }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
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

private final class CreationRequestRecorder: @unchecked Sendable {
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

private final class CreationAccountStore: AccountJSONStore, @unchecked Sendable {
    private let lock = NSLock()
    private var json = #"{"cookies":{"d_c0":"device","_xsrf":"token"},"userAgent":"test"}"#

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
        json = ""
        lock.unlock()
    }

    func update(_ transform: (String?) throws -> String?) throws {
        lock.lock()
        defer { lock.unlock() }
        json = try transform(json) ?? ""
    }
}
