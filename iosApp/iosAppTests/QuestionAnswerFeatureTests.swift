import Foundation
import XCTest
@testable import iosApp

final class QuestionAnswerFeatureTests: XCTestCase {
    override func tearDown() {
        QAURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testReadingPreferencesConsumeAnswerSwitchMode() throws {
        let suiteName = "QuestionAnswerFeatureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("off", forKey: "answerSwitchMode")
        XCTAssertFalse(QAReadingPreferences(defaults: defaults).answerSwitchEnabled)

        defaults.set("horizontal", forKey: "answerSwitchMode")
        XCTAssertTrue(QAReadingPreferences(defaults: defaults).answerSwitchEnabled)
    }

    func testRichContentParserProjectsSemanticBlocksAndPreservesTypedLinks() throws {
        let html = """
        <h2>标题</h2>
        <p data-segment-id="seg-1">正文 <strong>加粗</strong> <a href="/question/7">问题</a></p>
        <blockquote>引用</blockquote>
        <ol><li>第一项</li><li><em>第二项</em></li></ol>
        <pre><code class="language-swift">let value = 1</code></pre>
        <span class="ztext-math" data-tex="x^2+y^2"></span>
        <figure><img data-actualsrc="https://pic.zhimg.com/a.jpg" alt="图像"><figcaption>图注</figcaption></figure>
        """

        let blocks = QARichContentParser.blocks(from: html)

        XCTAssertTrue(blocks.contains { if case .heading(_, 2, _) = $0 { return true }; return false })
        let segment = try XCTUnwrap(blocks.first { if case .segment = $0 { return true }; return false })
        if case let .segment(_, id, runs) = segment {
            XCTAssertEqual(id, "seg-1")
            XCTAssertTrue(runs.contains { $0.style.contains(.strong) })
            XCTAssertTrue(runs.contains { $0.link == .question(7) })
        }
        XCTAssertTrue(blocks.contains { if case .quote = $0 { return true }; return false })
        XCTAssertTrue(blocks.contains { if case .list(_, .ordered, let items) = $0 { return items.count == 2 }; return false })
        XCTAssertTrue(blocks.contains { if case .code(_, "swift", let text) = $0 { return text.contains("let value") }; return false })
        XCTAssertTrue(blocks.contains { if case .formula(_, "x^2+y^2") = $0 { return true }; return false })
        XCTAssertTrue(blocks.contains {
            if case let .image(image) = $0 { return image.caption == "图注" && image.url.host == "pic.zhimg.com" }
            return false
        })
    }

    func testParserIgnoresNoscriptDuplicateAndRejectsDataImage() {
        let blocks = QARichContentParser.blocks(
            from: #"<figure><noscript><img src="https://pic.zhimg.com/duplicate.jpg"></noscript><img src="data:image/svg+xml,x" data-actualsrc="https://pic.zhimg.com/real.jpg"></figure>"#
        )
        let images = blocks.compactMap { block -> QAImageDTO? in
            guard case let .image(image) = block else { return nil }
            return image
        }
        XCTAssertEqual(images.map(\.url.absoluteString), ["https://pic.zhimg.com/real.jpg"])
    }

    func testParserProjectsZhihuVideoBoxInsteadOfTreatingCoverAsImage() throws {
        let blocks = QARichContentParser.blocks(from: """
        <a class="video-box" href="https://link.zhihu.com/?target=https%3A//www.zhihu.com/video/2029631316597973958" data-lens-id="2029631316597973958">
          <img src="https://pic.zhimg.com/video-cover.jpg" />
        </a>
        """)

        XCTAssertEqual(blocks.count, 1)
        guard case let .video(_, video) = try XCTUnwrap(blocks.first) else {
            return XCTFail("video-box should become a native video block")
        }
        XCTAssertEqual(video.videoID, 2_029_631_316_597_973_958)
        XCTAssertEqual(video.thumbnailURL?.absoluteString, "https://pic.zhimg.com/video-cover.jpg")
        XCTAssertEqual(video.destinationURL?.absoluteString, "https://www.zhihu.com/video/2029631316597973958")
    }

    func testParserNormalizesSchemeRelativeExternalLink() throws {
        let blocks = QARichContentParser.blocks(
            from: #"<p><a href="//example.com/path">外部链接</a></p>"#
        )
        guard case let .paragraph(_, runs) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(runs.first?.link, .external(URL(string: "https://example.com/path")!))
    }

    func testPinDateNeverMovesIPFromTrailingMetadata() {
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: true).dateEdge, .leading)
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: true).ipEdge, .trailing)
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: false).dateEdge, .trailing)
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: false).ipEdge, .trailing)
    }

    func testQuestionRepositoryBuildsSortContractAndMapsFullQuestion() async throws {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            if request.url?.path.hasSuffix("/feeds") == true {
                return (200, QAFixtures.answerPage(next: nil), [:])
            }
            return (200, QAFixtures.question, [:])
        }
        let repository = makeRepository()

        let question = try await repository.fetchQuestion(QuestionRouteDTO(questionID: 7))
        let page = try await repository.fetchQuestionAnswers(questionID: 7, sort: .updated, after: nil)

        XCTAssertEqual(question.title, "原生问题")
        XCTAssertEqual(question.detailBlocks.count, 1)
        XCTAssertTrue(question.isFollowing)
        XCTAssertEqual(page.items.map(\.answerID), [42])
        let feedRequest = try XCTUnwrap(recorder.requests.first { $0.url?.path.hasSuffix("/feeds") == true })
        XCTAssertTrue(feedRequest.url?.query?.contains("order=updated") == true)
        XCTAssertTrue(feedRequest.url?.query?.contains("include=") == true)
    }

    func testQuestionAndAnswerReadRequestsUseAuthenticatedSignature() async throws {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            switch request.url?.path {
            case "/api/v4/questions/7":
                return (200, QAFixtures.question, [:])
            case "/api/v4/questions/7/feeds":
                return (200, QAFixtures.answerPage(next: nil), [:])
            default:
                return (200, QAFixtures.answer, [:])
            }
        }
        let repository = makeRepository()

        _ = try await repository.fetchQuestion(QuestionRouteDTO(questionID: 7))
        _ = try await repository.fetchQuestionAnswers(questionID: 7, sort: .default, after: nil)
        _ = try await repository.fetchAnswer(
            AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7)
        )

        XCTAssertEqual(recorder.requests.count, 3)
        for request in recorder.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "d_c0=device; z_c0=login")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-zse-93"), ZhihuRequestSignature.zse93)
            XCTAssertTrue(request.value(forHTTPHeaderField: "x-zse-96")?.hasPrefix("2.0_") == true)
        }
    }

    func testQuestionAndAnswerReadRequestsRejectMissingAccountBeforeNetwork() async {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, Data(), [:])
        }
        let repository = makeRepository(accountStore: QAAccountStore(json: nil))

        do {
            _ = try await repository.fetchQuestion(QuestionRouteDTO(questionID: 7))
            XCTFail("Expected question authentication failure")
        } catch {
            XCTAssertEqual(error as? ZhihuAPIError, .authenticationRequired)
        }
        do {
            _ = try await repository.fetchQuestionAnswers(
                questionID: 7,
                sort: .default,
                after: nil
            )
            XCTFail("Expected question feed authentication failure")
        } catch {
            XCTAssertEqual(error as? ZhihuAPIError, .authenticationRequired)
        }
        do {
            _ = try await repository.fetchAnswer(
                AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7)
            )
            XCTFail("Expected answer authentication failure")
        } catch {
            XCTAssertEqual(error as? ZhihuAPIError, .authenticationRequired)
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testAnswerRepositoryMapsBlocksEndorsementMetadataAndUnknownFavorite() async throws {
        QAURLProtocol.setHandler { _ in (200, QAFixtures.answer, [:]) }
        let repository = makeRepository()

        let answer = try await repository.fetchAnswer(
            AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7)
        )

        XCTAssertEqual(answer.title, "原生问题")
        XCTAssertEqual(answer.author.displayName, "作者")
        XCTAssertEqual(answer.voteState, .up)
        XCTAssertEqual(answer.favoriteState, .unknown)
        XCTAssertEqual(answer.ipLocation, "江苏")
        XCTAssertEqual(answer.endorsements.first?.text, "周刊收录")
        XCTAssertEqual(answer.endorsements.first?.actionURL?.path, "/weekly/1")
        XCTAssertEqual(
            answer.sourceURL.absoluteString,
            "https://www.zhihu.com/question/7/answer/42"
        )
        XCTAssertNil(answer.invitationPreface, "thanks_count must never be guessed as the user-visible 谢邀 preface")
        XCTAssertTrue(answer.blocks.contains { if case .paragraph = $0 { return true }; return false })
    }

    func testAnswerRepositoryMergesAttachmentPlaybackIntoMatchingVideoBoxWithoutDuplicate() async throws {
        let payload = Data(#"""
        {
          "id":42,
          "content":"<a class=\"video-box\" data-lens-id=\"99\" href=\"https://www.zhihu.com/video/99\"><img src=\"https://pic.zhimg.com/cover.jpg\"></a>",
          "author":{"id":"member","url_token":"author","name":"作者","headline":"","avatar_url":"https://pic.zhimg.com/avatar.jpg"},
          "question":{"id":7,"title":"原生问题"},
          "attachment":{"type":"video","attachment_id":"99","video":{"video_info":{"thumbnail":"https://pic.zhimg.com/cover.jpg","playlist":{"hd":{"play_url":"https://vdn1.vzuu.com/video.mp4"}}}}},
          "voteup_count":1,"comment_count":0,"created_time":1,"updated_time":1
        }
        """#.utf8)
        QAURLProtocol.setHandler { _ in (200, payload, [:]) }

        let answer = try await makeRepository().fetchAnswer(
            AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7)
        )
        let videos = answer.blocks.compactMap { block -> QAAttachmentVideoDTO? in
            guard case let .video(_, video) = block else { return nil }
            return video
        }

        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos.first?.videoID, 99)
        XCTAssertEqual(videos.first?.playbackURL?.absoluteString, "https://vdn1.vzuu.com/video.mp4")
        XCTAssertNil(answer.attachment)
    }

    func testUntrustedQuestionContinuationIsRejectedBeforeSecondRequest() async throws {
        QAURLProtocol.setHandler { _ in
            (200, QAFixtures.answerPage(next: "https://attacker.example/steal"), [:])
        }
        let repository = makeRepository()

        do {
            _ = try await repository.fetchQuestionAnswers(questionID: 7, sort: .default, after: nil)
            XCTFail("Expected continuation rejection")
        } catch QuestionAnswerRepositoryError.untrustedContinuation {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testQuestionContinuationKeepsFeedIncludeContract() async throws {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            let isContinuation = request.url?.query?.contains("offset=20") == true
            return (
                200,
                QAFixtures.answerPage(
                    next: isContinuation
                        ? nil
                        : "https://www.zhihu.com/api/v4/questions/7/feeds?limit=20&order=updated&offset=20"
                ),
                [:]
            )
        }
        let repository = makeRepository()

        let firstPage = try await repository.fetchQuestionAnswers(
            questionID: 7,
            sort: .updated,
            after: nil
        )
        _ = try await repository.fetchQuestionAnswers(
            questionID: 7,
            sort: .updated,
            after: try XCTUnwrap(firstPage.nextURL)
        )

        let continuation = try XCTUnwrap(
            recorder.requests.first { $0.url?.query?.contains("offset=20") == true }
        )
        XCTAssertTrue(
            continuation.url?.query?.contains(
                "include=data%5B*%5D.content,excerpt,headline,target.author.badge_v2"
            ) == true
        )
    }

    func testVoteUsesAnswerStatePayloadAndPublishesServerCount() async throws {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, Data(#"{"voteup_count":101}"#.utf8), [:])
        }
        let repository = makeRepository()

        let result = try await repository.setVote(
            .down,
            route: AnswerRouteDTO(contentID: 42, kind: .answer)
        )

        XCTAssertEqual(result, QAVoteMutationResult(state: .down, voteUpCount: 101))
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v4/answers/42/voters")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: String])?["type"], "down")
    }

    @MainActor
    func testQuestionRefreshFailurePreservesPreviouslyVisibleQuestionAndAnswers() async {
        let repository = StubQuestionAnswerRepository()
        repository.questionResult = .success(QAFixtures.questionDTO)
        repository.answerPageResults = [.success(QAFixtures.answerPageDTO)]
        let store = QuestionStore(route: QuestionRouteDTO(questionID: 7), repository: repository)
        await store.refresh()
        repository.questionResult = .failure(QAStubError.failed)
        repository.answerPageResults = [.failure(QAStubError.failed)]

        await store.refresh()

        XCTAssertEqual(store.question?.title, "原生问题")
        XCTAssertEqual(store.answers.map(\.answerID), [42])
        XCTAssertEqual(store.initialLoad, .failed("测试失败"))
    }

    @MainActor
    func testQuestionSourcePreservesClickedPositionForPager() {
        let repository = StubQuestionAnswerRepository()
        let answers = [40, 41, 42, 43].map(QAFixtures.preview)
        let route = AnswerRouteDTO(
            contentID: 42,
            kind: .answer,
            questionID: 7,
            source: AnswerPageSourceDTO(
                questionID: 7,
                order: .updated,
                orderedAnswers: answers,
                selectedAnswerID: 42,
                nextURL: nil
            )
        )

        let pager = AnswerPagerStore(
            route: route,
            repository: repository,
            openedHistory: StubOpenedHistory()
        )

        XCTAssertEqual(pager.current.id, 42)
        XCTAssertEqual(pager.previous?.id, 41)
        XCTAssertEqual(pager.next?.id, 43)
    }

    @MainActor
    func testPagerContinuesAcrossPagesUntilItFindsAnUnopenedAnswer() async {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .success(QAFixtures.answerDTO)
        repository.answerPageResults = [
            .success(
                QuestionAnswerPageDTO(
                    items: [QAFixtures.preview(43)],
                    nextURL: URL(string: "https://www.zhihu.com/api/v4/questions/7/feeds?offset=20"),
                    isEnd: false
                )
            ),
            .success(
                QuestionAnswerPageDTO(
                    items: [QAFixtures.preview(44)],
                    nextURL: nil,
                    isEnd: true
                )
            ),
        ]
        let pager = AnswerPagerStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: repository,
            openedHistory: StubOpenedHistory(opened: [43])
        )

        await pager.prepare()

        XCTAssertEqual(pager.next?.id, 44)
    }

    @MainActor
    func testPagerKeepsPublishingNeighborsAcrossInitialAndLoadedPages() async {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .success(QAFixtures.answerDTO)
        repository.answerPageResults = [
            .success(
                QuestionAnswerPageDTO(
                    items: [44, 45, 46].map(QAFixtures.preview),
                    nextURL: nil,
                    isEnd: true
                )
            ),
        ]
        let initial = [40, 41, 42, 43].map(QAFixtures.preview)
        let pager = AnswerPagerStore(
            route: AnswerRouteDTO(
                contentID: 40,
                kind: .answer,
                questionID: 7,
                source: AnswerPageSourceDTO(
                    questionID: 7,
                    order: .default,
                    orderedAnswers: initial,
                    selectedAnswerID: 40,
                    nextURL: URL(string: "https://www.zhihu.com/api/v4/questions/7/feeds?offset=4")
                )
            ),
            repository: repository,
            openedHistory: StubOpenedHistory()
        )

        await pager.prepare()
        XCTAssertEqual(pager.next?.id, 41)
        for expected in [41, 42, 43, 44, 45, 46] {
            await pager.didDisplay(answerID: Int64(expected))
            XCTAssertEqual(pager.current.id, Int64(expected))
            XCTAssertEqual(pager.next?.id, expected == 46 ? nil : Int64(expected + 1))
        }
    }

    @MainActor
    func testPagerDistinguishesLoadingAvailableEndAndFailedForwardStates() async {
        let availableRepository = StubQuestionAnswerRepository()
        let availableRoute = AnswerRouteDTO(
            contentID: 42,
            kind: .answer,
            questionID: 7,
            source: AnswerPageSourceDTO(
                questionID: 7,
                order: .default,
                orderedAnswers: [42, 43].map(QAFixtures.preview),
                selectedAnswerID: 42,
                nextURL: nil
            )
        )
        let availablePager = AnswerPagerStore(
            route: availableRoute,
            repository: availableRepository,
            openedHistory: StubOpenedHistory()
        )
        XCTAssertEqual(availablePager.forwardAvailability, .available)

        let endRepository = StubQuestionAnswerRepository()
        endRepository.answerResult = .success(QAFixtures.answerDTO)
        endRepository.answerPageResults = [
            .success(QuestionAnswerPageDTO(items: [], nextURL: nil, isEnd: true)),
        ]
        let endPager = AnswerPagerStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: endRepository,
            openedHistory: StubOpenedHistory()
        )
        XCTAssertEqual(endPager.forwardAvailability, .loading)
        endPager.reportForwardBoundaryReached()
        XCTAssertNil(endPager.boundaryNotice)
        await endPager.prepare()
        XCTAssertEqual(endPager.forwardAvailability, .end)
        endPager.reportForwardBoundaryReached()
        XCTAssertEqual(endPager.boundaryNotice, "没有更多了")

        let failedRepository = StubQuestionAnswerRepository()
        failedRepository.answerResult = .success(QAFixtures.answerDTO)
        failedRepository.answerPageResults = [.failure(QAStubError.failed)]
        let failedPager = AnswerPagerStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: failedRepository,
            openedHistory: StubOpenedHistory()
        )
        await failedPager.prepare()
        XCTAssertEqual(failedPager.forwardAvailability, .failed("测试失败"))
    }

    @MainActor
    func testPagerCommitsDisplayedAnswerBeforeAsyncPreparation() {
        let repository = StubQuestionAnswerRepository()
        let route = AnswerRouteDTO(
            contentID: 40,
            kind: .answer,
            questionID: 7,
            source: AnswerPageSourceDTO(
                questionID: 7,
                order: .default,
                orderedAnswers: [40, 41, 42].map(QAFixtures.preview),
                selectedAnswerID: 40,
                nextURL: nil
            )
        )
        let pager = AnswerPagerStore(
            route: route,
            repository: repository,
            openedHistory: StubOpenedHistory()
        )

        XCTAssertTrue(pager.commitDisplayedAnswer(answerID: 41))

        XCTAssertEqual(pager.current.id, 41)
        XCTAssertEqual(pager.previous?.id, 40)
        XCTAssertEqual(pager.next?.id, 42)
    }

    private func makeRepository(
        accountStore: AccountJSONStore = QAAccountStore()
    ) -> URLSessionQuestionAnswerRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QAURLProtocol.self]
        let client = ZhihuAPIClient(
            accountStore: accountStore,
            session: URLSession(configuration: configuration)
        )
        return URLSessionQuestionAnswerRepository(client: client)
    }
}

private enum QAFixtures {
    static let question = Data(
        #"{"id":7,"title":"原生问题","detail":"<p>问题描述</p>","answer_count":1,"visit_count":20,"comment_count":3,"follower_count":4,"relationship":{"is_following":true},"author":{"id":"owner","url_token":"owner","name":"提问者","headline":"","avatar_url":"https://pic.zhimg.com/owner.jpg"},"topics":[{"id":"9","name":"iOS","url":"https://www.zhihu.com/topic/9"}]}"#.utf8
    )

    static let answer = Data(
        #"{"id":42,"content":"<p>回答正文</p>","author":{"id":"member","url_token":"author","name":"作者","headline":"简介","avatar_url":"https://pic.zhimg.com/avatar.jpg"},"question":{"id":7,"title":"原生问题"},"attachment":null,"voteup_count":100,"favlists_count":2,"comment_count":3,"thanks_count":99,"created_time":1000,"updated_time":2000,"ip_info":"江苏","url":"https://www.zhihu.com/question/7/answer/42","reaction":{"relation":{"vote":"UP"}},"endorsements":[{"action_url":"https://www.zhihu.com/weekly/1","elements":[{"type":"IMAGE","image_key":"seal"},{"type":"TEXT","content":"周刊收录"},{"type":"IMAGE","image_key":"arrow"}]}]}"#.utf8
    )

    static func answerPage(next: String?) -> Data {
        let nextValue = next.map { "\"\($0)\"" } ?? "null"
        return Data(
            (#"{"data":[{"target":{"type":"answer","id":42,"excerpt":"<p>摘要</p>","voteup_count":8,"comment_count":2,"author":{"id":"member","url_token":"author","name":"作者","headline":"简介","avatar_url":"https://pic.zhimg.com/avatar.jpg"},"question":{"id":7,"title":"原生问题"}}}],"paging":{"is_end":false,"next":"# + nextValue + "}}").utf8
        )
    }

    static let author = QAAuthorDTO(
        memberID: "member",
        urlToken: "author",
        displayName: "作者",
        headline: "简介",
        avatarURL: URL(string: "https://pic.zhimg.com/avatar.jpg")
    )

    static let questionDTO = QuestionDTO(
        id: 7,
        title: "原生问题",
        detailHTML: "<p>问题描述</p>",
        detailBlocks: [.paragraph(UUID(), [QAInlineRun(text: "问题描述")])],
        answerCount: 1,
        visitCount: 20,
        commentCount: 3,
        followerCount: 4,
        isFollowing: false,
        author: nil,
        topics: []
    )

    static func preview(_ id: Int) -> AnswerPreviewDTO {
        AnswerPreviewDTO(
            answerID: Int64(id),
            questionID: 7,
            questionTitle: "原生问题",
            author: author,
            excerpt: "摘要",
            voteUpCount: id,
            commentCount: 1
        )
    }

    static let answerPageDTO = QuestionAnswerPageDTO(items: [preview(42)], nextURL: nil, isEnd: true)

    static let answerDTO = AnswerDTO(
        route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
        title: "原生问题",
        questionID: 7,
        author: author,
        blocks: [.paragraph(UUID(), [QAInlineRun(text: "正文")])],
        attachment: nil,
        sourceURL: URL(string: "https://www.zhihu.com/question/7/answer/42")!,
        voteUpCount: 1,
        favoriteCount: 0,
        commentCount: 0,
        voteState: .neutral,
        favoriteState: .unknown,
        createdTimeSeconds: 1,
        updatedTimeSeconds: 1,
        ipLocation: nil,
        invitationPreface: nil,
        endorsements: []
    )
}

private final class QARequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [URLRequest] = []
    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func record(_ request: URLRequest) {
        let captured = URLRequestBodyCapture.capture(request)
        lock.lock(); value.append(captured); lock.unlock()
    }
}

private final class QAURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])
    private static let lock = NSLock()
    private static var handler: Handler?

    static func setHandler(_ value: Handler?) {
        lock.lock(); handler = value; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: QAStubError.failed)
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
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

private final class QAAccountStore: AccountJSONStore, @unchecked Sendable {
    private let lock = NSLock()
    private var json: String?
    init(json: String? = #"{"cookies":{"d_c0":"device","z_c0":"login"},"userAgent":"qa-test"}"#) {
        self.json = json
    }
    func load() throws -> String? { lock.lock(); defer { lock.unlock() }; return json }
    func save(_ value: String) throws { lock.lock(); json = value; lock.unlock() }
    func clear() throws { lock.lock(); json = nil; lock.unlock() }
    func update(_ transform: (String?) throws -> String?) throws {
        lock.lock(); defer { lock.unlock() }
        json = try transform(json)
    }
}

private enum QAStubError: LocalizedError { case failed; var errorDescription: String? { "测试失败" } }

private final class StubQuestionAnswerRepository: QuestionAnswerRepository, @unchecked Sendable {
    var questionResult: Result<QuestionDTO, Error> = .failure(QAStubError.failed)
    var answerPageResults: [Result<QuestionAnswerPageDTO, Error>] = []
    var answerResult: Result<AnswerDTO, Error> = .failure(QAStubError.failed)

    func fetchQuestion(_ route: QuestionRouteDTO) async throws -> QuestionDTO { try questionResult.get() }
    func fetchQuestionAnswers(questionID: Int64, sort: QuestionAnswerSort, after nextURL: URL?) async throws -> QuestionAnswerPageDTO {
        guard !answerPageResults.isEmpty else { return QuestionAnswerPageDTO(items: [], nextURL: nil, isEnd: true) }
        return try answerPageResults.removeFirst().get()
    }
    func setQuestionFollowing(_ following: Bool, questionID: Int64) async throws {}
    func fetchAnswer(_ route: AnswerRouteDTO) async throws -> AnswerDTO { try answerResult.get() }
    func setVote(_ state: QAVoteState, route: AnswerRouteDTO) async throws -> QAVoteMutationResult {
        QAVoteMutationResult(state: state, voteUpCount: 1)
    }
    func fetchCollections(route: AnswerRouteDTO) async throws -> QACollectionsResult {
        QACollectionsResult(items: [], favoriteState: .notFavorited)
    }
    func setCollection(_ selected: Bool, collectionID: String, route: AnswerRouteDTO) async throws {}
}

private actor StubOpenedHistory: AnswerOpenedHistory {
    var opened: Set<Int64>
    init(opened: Set<Int64> = []) { self.opened = opened }
    func openedAnswerIDs(questionID: Int64) -> Set<Int64> { opened }
    func markOpened(answerID: Int64, questionID: Int64) { opened.insert(answerID) }
}
