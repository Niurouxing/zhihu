import Foundation
import UIKit
import XCTest
@testable import iosApp

final class QuestionAnswerFeatureTests: XCTestCase {
    override func tearDown() {
        QAURLProtocol.setHandler(nil)
        super.tearDown()
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

    func testParserPreservesTrustedZhihuImageDimensionsBeforeLoading() throws {
        let blocks = QARichContentParser.blocks(from: """
        <figure>
          <img
            src="https://pic.zhimg.com/example.jpg"
            data-rawwidth="1200"
            data-rawheight="880"
            width="300"
            height="200"
          />
          <figcaption>尺寸图</figcaption>
        </figure>
        """)

        guard case let .image(image) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected image")
        }
        XCTAssertEqual(image.dimensions, QAImageDimensions(width: 1200, height: 880))
        XCTAssertEqual(
            try XCTUnwrap(image.dimensions).aspectRatio,
            1200.0 / 880.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(image.caption, "尺寸图")
    }

    func testParserFallsBackToWidthHeightAndRejectsUntrustedImageDimensions() {
        let blocks = QARichContentParser.blocks(from: """
        <img src="https://pic.zhimg.com/fallback.jpg"
             data-rawwidth="unknown" data-rawheight="unknown"
             width="640" height="480" />
        <img src="https://pic.zhimg.com/invalid.jpg" data-rawwidth="-1" data-rawheight="999999999" />
        """)
        let images = blocks.compactMap { block -> QAImageDTO? in
            guard case let .image(image) = block else { return nil }
            return image
        }

        XCTAssertEqual(images.first?.dimensions, QAImageDimensions(width: 640, height: 480))
        XCTAssertNil(images.last?.dimensions)
    }

    func testParserPreservesNestedAndSiblingListHierarchyAndOrderedStart() throws {
        let blocks = QARichContentParser.blocks(from: """
        <ol start="3">
          <li>继续跳票。</li>
          <li>在较短时间内推出，但是</li>
          <ol>
            <li>分词器和灰测表现不一致</li>
            <ol>
              <li>正式版性能约等于 Fable。</li>
              <li>正式版性能远不及 Fable。</li>
            </ol>
            <li>分词器和灰测表现一致</li>
          </ol>
        </ol>
        """)

        guard case let .list(_, .ordered, items) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected ordered list")
        }
        XCTAssertEqual(items.map(\.ordinal), [3, 4])
        XCTAssertEqual(items.map { $0.runs.map(\.text).joined() }, ["继续跳票。", "在较短时间内推出，但是"])
        let secondLevel = try XCTUnwrap(items[1].nestedLists.first)
        XCTAssertEqual(secondLevel.kind, .ordered)
        XCTAssertEqual(secondLevel.items.count, 2)
        XCTAssertEqual(secondLevel.items[0].nestedLists.first?.items.count, 2)
    }

    func testParserKeepsItemsFromMalformedNestedListWithoutPrecedingItem() throws {
        let blocks = QARichContentParser.blocks(from: """
        <h3>1.2 国际带宽分配</h3>
        <ul><ul>
          <li>电信的国际带宽总量最大，约为7.7T</li>
          <li>带宽分配较为均衡，各省都有一定的国际带宽</li>
        </ul></ul>
        """)

        let list = try XCTUnwrap(blocks.first { block in
            if case .list = block { return true }
            return false
        })
        guard case let .list(_, .unordered, items) = list else {
            return XCTFail("expected unordered list")
        }
        XCTAssertEqual(
            items.map { $0.runs.map(\.text).joined() },
            ["电信的国际带宽总量最大，约为7.7T", "带宽分配较为均衡，各省都有一定的国际带宽"]
        )
    }

    func testSelectableRichTextKeepsStrikethroughAndTypedLinkInOneTextRun() throws {
        let blocks = QARichContentParser.blocks(
            from: #"<p><a href="/question/7"><del>可选择的划线链接</del></a></p>"#
        )
        guard case let .paragraph(_, runs) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(runs.first?.link, .question(7))
        XCTAssertTrue(try XCTUnwrap(runs.first).style.contains(.strikethrough))

        let attributed = QARichTextFormatter.attributed(runs)
        XCTAssertEqual(String(attributed.characters), "可选择的划线链接")
        XCTAssertEqual(attributed.runs.first?.link, URL(string: "zhihu://questions/7"))
        XCTAssertNotNil(attributed.runs.first?.strikethroughStyle)
    }

    func testLatexReadableFallbackSupportsEscapesSpacingAndConsecutiveScripts() {
        XCTAssertEqual(
            QALatexReadableText.render("\\{ \\} \\$ \\% \\# \\& \\_ \\| \\backslash"),
            "{ } $ % # & _ ‖ \\"
        )
        XCTAssertEqual(QALatexReadableText.render("a_ib_jx^{i+j}"), "aᵢbⱼxⁱ⁺ʲ")
        XCTAssertEqual(
            QALatexReadableText.render(#"\frac{a}{b}"#),
            #"\frac{a}{b}"#,
            "unknown commands must remain lossless"
        )
        XCTAssertEqual(
            QALatexReadableText.render(#"a\ b\,c\:d\>e\;f\quad g\qquad h"#),
            "a b\u{2009}c\u{2005}d\u{2005}e\u{2004}f\u{2003}g\u{2003}\u{2003}h"
        )
    }

    func testMarkdownConverterProjectsSemanticBlocksWithoutReparsingDisplayText() {
        let nested = QAListGroup(
            kind: .ordered,
            startIndex: 3,
            items: [
                QAListItem(runs: [QAInlineRun(text: "内层一")], ordinal: 3),
                QAListItem(
                    runs: [QAInlineRun(text: "内层二")],
                    ordinal: 4,
                    nestedLists: [
                        QAListGroup(
                            kind: .unordered,
                            items: [QAListItem(runs: [QAInlineRun(text: "三级")])]
                        ),
                    ]
                ),
            ]
        )
        let blocks: [QABodyBlock] = [
            .paragraph(UUID(), [
                QAInlineRun(text: "普通 * 文本 "),
                QAInlineRun(text: "加粗", style: .strong),
                QAInlineRun(text: " 强调", style: .emphasis),
                QAInlineRun(text: " 删除", style: .strikethrough, link: .question(7)),
                QAInlineRun(text: " code`value", style: .code),
            ]),
            .heading(UUID(), level: 3, runs: [QAInlineRun(text: "小节")]),
            .quote(UUID(), [QAInlineRun(text: "引用\n第二行")]),
            .list(
                UUID(),
                kind: .unordered,
                items: [
                    QAListItem(
                        runs: [QAInlineRun(text: "外层")],
                        nestedLists: [nested]
                    ),
                ]
            ),
            .code(UUID(), language: "swift unsafe", text: "let fence = ```"),
            .formula(UUID(), latex: "a_ib_j"),
            .image(QAImageDTO(
                url: URL(string: "https://pic.zhimg.com/a.jpg")!,
                caption: "说明",
                altText: "图]像"
            )),
            .segment(UUID(), segmentID: "seg", runs: [QAInlineRun(text: "划线正文")]),
            .divider(UUID()),
        ]

        XCTAssertEqual(
            QAMarkdownConverter.blocks(blocks),
            """
            普通 \\* 文本 **加粗** *强调* [~~删除~~](https://www.zhihu.com/question/7) ``code`value``

            ### 小节

            > 引用
            > 第二行

            - 外层
                3. 内层一
                4. 内层二
                    - 三级

            ````swift
            let fence = ```
            ````

            $$
            a_ib_j
            $$

            ![图\\]像](https://pic.zhimg.com/a.jpg)

            _说明_

            划线正文

            ---
            """
        )
    }

    func testMarkdownDocumentIncludesTitleAuthorSourceAndOnlyLoadedBlocks() {
        let answer = QAFixtures.answerDTO
        let document = QAMarkdownConverter.document(from: answer)

        XCTAssertEqual(document.title, "原生问题")
        XCTAssertEqual(document.authorName, "作者")
        XCTAssertEqual(document.sourceURL, answer.sourceURL)
        XCTAssertEqual(document.suggestedFileName, "原生问题.md")
        XCTAssertEqual(
            document.markdown,
            "# 原生问题\n\n作者：作者\n\n" +
                "原文：[https://www.zhihu.com/question/7/answer/42]" +
                "(https://www.zhihu.com/question/7/answer/42)\n\n正文\n"
        )

        let article = AnswerDTO(
            route: .init(contentID: 9, kind: .article),
            title: "文章 / 标题",
            questionID: nil,
            author: answer.author,
            blocks: [.paragraph(UUID(), [QAInlineRun(text: "当前已加载内容")])],
            attachment: nil,
            sourceURL: URL(string: "https://zhuanlan.zhihu.com/p/9")!,
            voteUpCount: 0,
            favoriteCount: 0,
            commentCount: 0,
            voteState: .neutral,
            favoriteState: .unknown,
            createdTimeSeconds: 0,
            updatedTimeSeconds: 0,
            ipLocation: nil,
            invitationPreface: nil,
            endorsements: []
        )
        let articleDocument = QAMarkdownConverter.document(from: article)
        XCTAssertTrue(articleDocument.markdown.contains("当前已加载内容"))
        XCTAssertFalse(articleDocument.markdown.contains("未加载"))
        XCTAssertEqual(articleDocument.suggestedFileName, "文章-标题.md")
    }

    func testMarkdownSharePayloadUsesTextThenFilePayloadForLongContent() {
        let short = QAMarkdownDocument(
            title: "短文",
            authorName: "作者",
            sourceURL: URL(string: "https://www.zhihu.com/answer/1")!,
            markdown: "短正文",
            suggestedFileName: "短文.md"
        )
        XCTAssertEqual(
            QAMarkdownSharePayloadBuilder.payload(for: short, inlineTextByteLimit: 100),
            .text("短正文")
        )

        let long = QAMarkdownDocument(
            title: "长文",
            authorName: "作者",
            sourceURL: short.sourceURL,
            markdown: String(repeating: "长", count: 101),
            suggestedFileName: "../../不可覆盖.md"
        )
        XCTAssertEqual(
            QAMarkdownSharePayloadBuilder.payload(for: long, inlineTextByteLimit: 100),
            .file(contents: long.markdown, suggestedFileName: "../../不可覆盖.md")
        )
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

    func testAppViewLinksResolveToTypedQADestinations() throws {
        XCTAssertEqual(
            QABodyLinkResolver.resolve(URL(string: "https://www.zhihu.com/appview/pin/11")!),
            .pin(11)
        )
        XCTAssertEqual(
            QABodyLinkResolver.resolve(URL(string: "https://www.zhihu.com/appview/answer/12")!),
            .answer(12)
        )
        XCTAssertEqual(
            QABodyLinkResolver.resolve(URL(string: "https://www.zhihu.com/appview/p/13")!),
            .article(13)
        )

        let external = URL(string: "https://attacker.example/appview/answer/12")!
        XCTAssertEqual(QABodyLinkResolver.resolve(external), .external(external))
    }

    func testRichContentParserUsesUnifiedAppViewResolver() throws {
        let blocks = QARichContentParser.blocks(
            from: #"<p><a href="/appview/pin/22">站内想法</a></p>"#
        )
        guard case let .paragraph(_, runs) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(runs.first?.link, .pin(22))
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

    func testVideoRepositoryPostsWebPlayerContractAndChoosesHighestTrustedBitrate() async throws {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            return (
                200,
                Data(
                    #"{"video_play":{"playlist":{"mp4":[{"bitrate":100,"url":["https://video.vzuu.com/low.mp4"]},{"bitrate":300,"url":["https://video.vzuu.com/high.mp4"]}]}}}"#.utf8
                ),
                [:]
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QAURLProtocol.self]
        let client = ZhihuAPIClient(
            accountStore: QAAccountStore(),
            session: URLSession(configuration: configuration)
        )
        let repository = URLSessionNativeVideoRepository(client: client)
        let route = NativeVideoRouteDTO(
            contentID: 42,
            videoID: 99,
            contentType: .answer
        )

        let playbackURL = try await repository.resolvePlaybackURL(for: route)

        XCTAssertEqual(playbackURL, URL(string: "https://video.vzuu.com/high.mp4"))
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v4/video/play_info")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "r" })?.value,
            "99"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-app-za"), "OS=webplayer")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["content_id"] as? String, "42")
        XCTAssertEqual(json["content_type_str"] as? String, "answer")
        XCTAssertEqual(json["video_id"] as? String, "99")
        XCTAssertEqual(json["scene_code"] as? String, "answer_detail_web")
        XCTAssertEqual(json["is_only_video"] as? Bool, true)
    }

    func testVideoRepositoryRejectsUntrustedPlaybackHost() async {
        QAURLProtocol.setHandler { _ in
            (
                200,
                Data(
                    #"{"video_play":{"playlist":{"mp4":[{"bitrate":300,"url":["https://attacker.example/video.mp4"]}]}}}"#.utf8
                ),
                [:]
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QAURLProtocol.self]
        let client = ZhihuAPIClient(
            accountStore: QAAccountStore(),
            session: URLSession(configuration: configuration)
        )
        let repository = URLSessionNativeVideoRepository(client: client)

        do {
            _ = try await repository.resolvePlaybackURL(for: .init(
                contentID: 42,
                videoID: 99,
                contentType: .answer
            ))
            XCTFail("Expected untrusted playback URL to be rejected")
        } catch {
            XCTAssertEqual(error as? NativeVideoRepositoryError, .playbackUnavailable)
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
        XCTAssertEqual(answer.endorsements.first?.actionURL?.path, "/column/c_1533471233991028736")
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
                "include=data%5B*%5D.excerpt,headline,target.author.badge_v2"
            ) == true
        )
    }

    func testAPIClientCachesAccountCredentialsUntilExplicitInvalidation() async throws {
        QAURLProtocol.setHandler { _ in (200, Data("{}".utf8), [:]) }
        let accountStore = QAAccountStore()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QAURLProtocol.self]
        let client = ZhihuAPIClient(
            accountStore: accountStore,
            session: URLSession(configuration: configuration)
        )
        let url = try XCTUnwrap(URL(string: "https://www.zhihu.com/api/v4/questions/7"))

        _ = try await client.data(for: url, authentication: .accountRequired)
        _ = try await client.data(for: url, authentication: .accountRequired)

        XCTAssertEqual(accountStore.loadCount, 1)

        await client.invalidateCredentialsCache()
        _ = try await client.data(for: url, authentication: .accountRequired)

        XCTAssertEqual(accountStore.loadCount, 2)
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

    func testReadHistoryUsesOfficialAddEndpointAndPayload() async throws {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, Data(#"{}"#.utf8), [:])
        }
        let repository = makeRepository()

        await repository.recordReadHistory(contentToken: "42", contentType: "answer")

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://www.zhihu.com/api/v4/read_history/add")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(payload["content_token"], "42")
        XCTAssertEqual(payload["content_type"], "answer")
    }

    func testReadHistoryIgnoresUnsupportedContentType() async {
        let recorder = QARequestRecorder()
        QAURLProtocol.setHandler { request in
            recorder.record(request)
            return (200, Data(#"{}"#.utf8), [:])
        }
        let repository = makeRepository()

        await repository.recordReadHistory(contentToken: "42", contentType: "advertisement")

        XCTAssertTrue(recorder.requests.isEmpty)
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
    func testQuestionSourcePlacesClickedAnswerFirstAndPreservesRemainingOrder() {
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

        let stream = AnswerStreamStore(
            route: route,
            repository: repository,
            openedHistory: StubOpenedHistory()
        )

        XCTAssertEqual(stream.current.id, 42)
        XCTAssertEqual(stream.answers.map(\.id), [42, 40, 41, 43])
        XCTAssertEqual(stream.paginationState, .end)
    }

    @MainActor
    func testVisibleFeedAnswerPreloadsAndSeedsStreamBeforeItsFirstFrame() async throws {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .success(QAFixtures.answerDTO)
        let preloader = NativeFeedAnswerPreloader(
            repository: repository,
            maximumCachedAnswers: 2,
            maximumConcurrentPreloads: 1
        )
        let item = FeedItemDTO(
            id: FeedItemID(kind: .answer, contentID: "42"),
            kind: .answer,
            title: "原生问题",
            summary: "信息流摘要",
            details: "1 赞同 · 0 评论",
            sourceLabel: nil,
            author: FeedAuthorDTO(
                memberID: "member",
                urlToken: "author",
                displayName: "作者",
                avatarURL: nil,
                headline: "简介"
            ),
            thumbnailURL: nil,
            route: .answer(answerID: 42, questionID: 7, questionTitle: "原生问题")
        )

        preloader.register(item)
        let route = try XCTUnwrap(item.route.answerRoute)
        let prefetched = try await preloader.answer(for: route)

        XCTAssertEqual(prefetched, QAFixtures.answerDTO)
        XCTAssertEqual(preloader.cachedPreview(for: route)?.summary, "信息流摘要")
        XCTAssertEqual(repository.answerFetchCount, 1)

        let stream = AnswerStreamStore(
            route: route,
            repository: repository,
            answerPreloader: preloader,
            openedHistory: StubOpenedHistory()
        )

        XCTAssertEqual(stream.current.content, QAFixtures.answerDTO)
        XCTAssertEqual(stream.current.loadState, .loaded)
        await stream.prepare()
        XCTAssertEqual(repository.answerFetchCount, 1)
    }

    @MainActor
    func testTappedFeedAnswerPromotesExistingRequestWithoutFetchingTwice() async throws {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .success(QAFixtures.answerDTO)
        let preloader = NativeFeedAnswerPreloader(
            repository: repository,
            maximumCachedAnswers: 2,
            maximumConcurrentPreloads: 1
        )
        let item = FeedItemDTO(
            id: FeedItemID(kind: .answer, contentID: "42"),
            kind: .answer,
            title: "原生问题",
            summary: "信息流摘要",
            details: "1 赞同 · 0 评论",
            sourceLabel: nil,
            author: nil,
            thumbnailURL: nil,
            route: .answer(answerID: 42, questionID: 7, questionTitle: "原生问题")
        )
        let route = try XCTUnwrap(item.route.answerRoute)

        preloader.promoteForNavigation(item)
        let answer = try await preloader.answer(for: route)

        XCTAssertEqual(answer, QAFixtures.answerDTO)
        XCTAssertEqual(repository.answerFetchCount, 1)
    }

    @MainActor
    func testConsumedAnswerRemainsCachedForImmediateReopen() async throws {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .success(QAFixtures.answerDTO)
        let preloader = NativeFeedAnswerPreloader(
            repository: repository,
            maximumCachedAnswers: 2,
            maximumConcurrentPreloads: 1
        )
        let route = AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7)

        let first = try await preloader.answer(for: route)
        for _ in 0 ..< 50 where preloader.cachedAnswer(for: route) == nil {
            await Task.yield()
        }
        let second = try await preloader.answer(for: route)

        XCTAssertEqual(first, QAFixtures.answerDTO)
        XCTAssertEqual(second, QAFixtures.answerDTO)
        XCTAssertNotNil(preloader.cachedAnswer(for: route))
        XCTAssertEqual(repository.answerFetchCount, 1)
    }

    @MainActor
    func testPreloaderFailureDoesNotTriggerAnImmediateDuplicateFetch() async {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .failure(QAStubError.failed)
        let preloader = NativeFeedAnswerPreloader(repository: repository)
        let store = AnswerStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: repository,
            answerPreloader: preloader
        )

        await store.retry()

        XCTAssertEqual(store.loadState, .failed("测试失败"))
        XCTAssertEqual(repository.answerFetchCount, 1)
    }

    @MainActor
    func testReadingSessionPrefetchesOnlyTheFollowingAnswer() async {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .success(QAFixtures.answerDTO(id: 44))
        let preloader = NativeFeedAnswerPreloader(repository: repository)
        preloader.cacheUpdatedAnswer(QAFixtures.answerDTO)
        let route = AnswerRouteDTO(
            contentID: 42,
            kind: .answer,
            questionID: 7,
            source: AnswerPageSourceDTO(
                questionID: 7,
                order: .default,
                orderedAnswers: [QAFixtures.preview(42), QAFixtures.preview(44), QAFixtures.preview(45)],
                selectedAnswerID: 42,
                nextURL: nil
            )
        )
        let stream = AnswerStreamStore(
            route: route,
            repository: repository,
            answerPreloader: preloader,
            followingAnswerPrefetchDelayNanoseconds: 0,
            openedHistory: StubOpenedHistory()
        )
        let followingRoute = AnswerRouteDTO(contentID: 44, kind: .answer, questionID: 7)
        let laterRoute = AnswerRouteDTO(contentID: 45, kind: .answer, questionID: 7)

        stream.focus(answerID: 42)
        for _ in 0 ..< 200 where preloader.cachedAnswer(for: followingRoute) == nil {
            await Task.yield()
        }

        XCTAssertNotNil(preloader.cachedAnswer(for: followingRoute))
        XCTAssertNil(preloader.cachedAnswer(for: laterRoute))
        XCTAssertEqual(repository.answerFetchCount, 1)
        stream.cancelPendingReadingPrefetches()
    }

    @MainActor
    func testURLSessionCancellationNeverBecomesVisibleAnswerFailure() async {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .failure(URLError(.cancelled))
        let store = AnswerStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: repository
        )

        await store.retry()

        XCTAssertEqual(store.loadState, .idle)
        XCTAssertNil(store.content)
    }

    @MainActor
    func testURLSessionCancellationKeepsAnswerPaginationRetryable() async {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .success(QAFixtures.answerDTO)
        repository.answerPageResults = [
            .failure(URLError(.cancelled)),
            .success(QuestionAnswerPageDTO(items: [], nextURL: nil, isEnd: true)),
        ]
        let continuation = URL(string: "https://www.zhihu.com/api/v4/questions/7/feeds?offset=20")!
        let stream = AnswerStreamStore(
            route: AnswerRouteDTO(
                contentID: 42,
                kind: .answer,
                questionID: 7,
                source: AnswerPageSourceDTO(
                    questionID: 7,
                    order: .default,
                    orderedAnswers: [QAFixtures.preview(42)],
                    selectedAnswerID: 42,
                    nextURL: continuation
                )
            ),
            repository: repository,
            openedHistory: StubOpenedHistory()
        )

        await stream.prepare()

        XCTAssertEqual(stream.current.loadState, .loaded)
        XCTAssertEqual(stream.paginationState, .idle)

        await stream.loadMoreIfNeeded()

        XCTAssertEqual(stream.paginationState, .end)
    }

    @MainActor
    func testStalledCommentPrefetchCannotBlockInitialAnswerPagination() async {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .success(QAFixtures.answerDTO)
        repository.answerPageResults = [
            .success(QuestionAnswerPageDTO(items: [], nextURL: nil, isEnd: true)),
        ]
        let commentRepository = GatedCommentRepository()
        let commentPreloader = NativeCommentPreloader(repository: commentRepository)
        let stream = AnswerStreamStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: repository,
            commentPreloader: commentPreloader,
            commentPrefetchDelayNanoseconds: 0,
            openedHistory: StubOpenedHistory()
        )

        let preparation = Task { await stream.prepare() }
        var commentStarted = false
        var paginationStarted = false
        for _ in 0 ..< 200 {
            commentStarted = await commentRepository.hasStarted
            paginationStarted = repository.answerPageFetchCount > 0
            if commentStarted, paginationStarted { break }
            await Task.yield()
        }
        await commentRepository.release()
        await preparation.value

        XCTAssertTrue(commentStarted)
        XCTAssertTrue(paginationStarted)
        XCTAssertEqual(stream.paginationState, .end)
    }

    @MainActor
    func testQuicklyDismissedAnswerDoesNotStartCommentSpeculation() async {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .success(QAFixtures.answerDTO)
        repository.answerPageResults = [
            .success(QuestionAnswerPageDTO(items: [], nextURL: nil, isEnd: true)),
        ]
        let commentRepository = GatedCommentRepository()
        let stream = AnswerStreamStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: repository,
            commentPreloader: NativeCommentPreloader(repository: commentRepository),
            commentPrefetchDelayNanoseconds: 60_000_000_000,
            openedHistory: StubOpenedHistory()
        )

        await stream.prepare()
        stream.cancelPendingCommentPrefetch()

        let commentStarted = await commentRepository.hasStarted
        XCTAssertFalse(commentStarted)
        XCTAssertEqual(stream.paginationState, .end)
    }

    @MainActor
    func testBackgroundAnswerPrefetchDoesNotPublishLoadingIndicatorUntilReaderReachesEnd() async {
        let repository = StubQuestionAnswerRepository()
        repository.answerPageDelayNanoseconds = 1_000_000_000
        repository.answerPageResults = [
            .success(QuestionAnswerPageDTO(items: [], nextURL: nil, isEnd: true)),
        ]
        let stream = AnswerStreamStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: repository,
            paginationTimeoutNanoseconds: 5_000_000_000,
            openedHistory: StubOpenedHistory()
        )

        let prefetch = Task {
            await stream.loadMoreIfNeeded(showsLoadingIndicator: false)
        }
        for _ in 0 ..< 200 {
            if stream.paginationState == .loading(showsIndicator: false) { break }
            await Task.yield()
        }

        XCTAssertEqual(stream.paginationState, .loading(showsIndicator: false))

        await stream.loadMoreIfNeeded(showsLoadingIndicator: true)

        XCTAssertEqual(stream.paginationState, .loading(showsIndicator: true))
        prefetch.cancel()
        await prefetch.value
        XCTAssertEqual(stream.paginationState, .idle)
    }

    @MainActor
    func testAnswerPaginationTimeoutBecomesRetryableFailureInsteadOfInfiniteLoading() async {
        let repository = StubQuestionAnswerRepository()
        repository.answerPageDelayNanoseconds = 1_000_000_000
        repository.answerPageResults = [
            .success(QuestionAnswerPageDTO(items: [], nextURL: nil, isEnd: true)),
        ]
        let stream = AnswerStreamStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: repository,
            paginationTimeoutNanoseconds: 1_000_000,
            openedHistory: StubOpenedHistory()
        )

        await stream.loadMoreIfNeeded()

        guard case let .failed(message) = stream.paginationState else {
            return XCTFail("超时必须结束加载状态并提供重试")
        }
        XCTAssertEqual(message, "加载更多回答超时，请重试")
    }

    @MainActor
    func testStreamContinuesPastEmptyPagesWithoutPublishingFalseEndState() async {
        let repository = StubQuestionAnswerRepository()
        repository.answerResult = .success(QAFixtures.answerDTO)
        repository.answerPageResults = [
            .success(
                QuestionAnswerPageDTO(
                    items: [],
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
        let stream = AnswerStreamStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: repository,
            openedHistory: StubOpenedHistory()
        )

        await stream.prepare()

        XCTAssertEqual(stream.answers.map(\.id), [42, 44])
        XCTAssertEqual(stream.paginationState, .end)
    }

    @MainActor
    func testStreamAppendsLoadedPagesWithoutReorderingExistingAnswers() async {
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
        let stream = AnswerStreamStore(
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

        await stream.loadMoreIfNeeded()

        XCTAssertEqual(stream.answers.map(\.id), [40, 41, 42, 43, 44, 45, 46])
        XCTAssertEqual(stream.paginationState, .end)
        stream.focus(answerID: 45)
        XCTAssertEqual(stream.current.id, 45)
    }

    @MainActor
    func testStreamDistinguishesAvailableContentEndAndFailedPagination() async {
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
        let availableStream = AnswerStreamStore(
            route: availableRoute,
            repository: availableRepository,
            openedHistory: StubOpenedHistory()
        )
        XCTAssertEqual(availableStream.answers.map(\.id), [42, 43])
        XCTAssertEqual(availableStream.paginationState, .end)

        let endRepository = StubQuestionAnswerRepository()
        endRepository.answerResult = .success(QAFixtures.answerDTO)
        endRepository.answerPageResults = [
            .success(QuestionAnswerPageDTO(items: [], nextURL: nil, isEnd: true)),
        ]
        let endStream = AnswerStreamStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: endRepository,
            openedHistory: StubOpenedHistory()
        )
        XCTAssertEqual(endStream.paginationState, .idle)
        await endStream.prepare()
        XCTAssertEqual(endStream.paginationState, .end)

        let failedRepository = StubQuestionAnswerRepository()
        failedRepository.answerResult = .success(QAFixtures.answerDTO)
        failedRepository.answerPageResults = [.failure(QAStubError.failed)]
        let failedStream = AnswerStreamStore(
            route: AnswerRouteDTO(contentID: 42, kind: .answer, questionID: 7),
            repository: failedRepository,
            openedHistory: StubOpenedHistory()
        )
        await failedStream.prepare()
        XCTAssertEqual(failedStream.paginationState, .failed("测试失败"))
    }

    @MainActor
    func testStreamFocusChangesCurrentAnswerWithoutChangingReadingOrder() {
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
        let stream = AnswerStreamStore(
            route: route,
            repository: repository,
            openedHistory: StubOpenedHistory()
        )

        stream.focus(answerID: 41)

        XCTAssertEqual(stream.current.id, 41)
        XCTAssertEqual(stream.answers.map(\.id), [40, 41, 42])
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
        #"{"id":42,"content":"<p>回答正文</p>","author":{"id":"member","url_token":"author","name":"作者","headline":"简介","avatar_url":"https://pic.zhimg.com/avatar.jpg"},"question":{"id":7,"title":"原生问题"},"attachment":null,"voteup_count":100,"favlists_count":2,"comment_count":3,"thanks_count":99,"created_time":1000,"updated_time":2000,"ip_info":"江苏","url":"https://www.zhihu.com/question/7/answer/42","reaction":{"relation":{"vote":"UP"}},"endorsements":[{"action_url":"https://www.zhihu.com/column/c_1533471233991028736","elements":[{"type":"IMAGE","image_key":"seal"},{"type":"TEXT","content":"周刊收录"},{"type":"IMAGE","image_key":"arrow"}]}]}"#.utf8
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

    static let answerDTO = answerDTO(id: 42)

    static func answerDTO(id: Int64) -> AnswerDTO {
        AnswerDTO(
            route: AnswerRouteDTO(contentID: id, kind: .answer, questionID: 7),
            title: "原生问题",
            questionID: 7,
            author: author,
            blocks: [.paragraph(UUID(), [QAInlineRun(text: "正文")])],
            attachment: nil,
            sourceURL: URL(string: "https://www.zhihu.com/question/7/answer/\(id)")!,
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
    private var loads = 0
    init(json: String? = #"{"cookies":{"d_c0":"device","z_c0":"login"},"userAgent":"qa-test"}"#) {
        self.json = json
    }
    var loadCount: Int { lock.lock(); defer { lock.unlock() }; return loads }
    func load() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        loads += 1
        return json
    }
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
    var answerPageDelayNanoseconds: UInt64 = 0
    var answerResult: Result<AnswerDTO, Error> = .failure(QAStubError.failed)
    private(set) var answerFetchCount = 0
    private(set) var answerPageFetchCount = 0

    func fetchQuestion(_ route: QuestionRouteDTO) async throws -> QuestionDTO { try questionResult.get() }
    func fetchQuestionAnswers(questionID: Int64, sort: QuestionAnswerSort, after nextURL: URL?) async throws -> QuestionAnswerPageDTO {
        answerPageFetchCount += 1
        if answerPageDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: answerPageDelayNanoseconds)
        }
        guard !answerPageResults.isEmpty else { return QuestionAnswerPageDTO(items: [], nextURL: nil, isEnd: true) }
        return try answerPageResults.removeFirst().get()
    }
    func setQuestionFollowing(_ following: Bool, questionID: Int64) async throws {}
    func fetchAnswer(_ route: AnswerRouteDTO) async throws -> AnswerDTO {
        answerFetchCount += 1
        return try answerResult.get()
    }
    func setVote(_ state: QAVoteState, route: AnswerRouteDTO) async throws -> QAVoteMutationResult {
        QAVoteMutationResult(state: state, voteUpCount: 1)
    }
    func fetchCollections(route: AnswerRouteDTO) async throws -> QACollectionsResult {
        QACollectionsResult(items: [], favoriteState: .notFavorited)
    }
    func setCollection(_ selected: Bool, collectionID: String, route: AnswerRouteDTO) async throws {}
}

private actor GatedCommentRepository: CommentRepository {
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    var hasStarted: Bool { started }

    func fetchPage(
        route: CommentThreadRouteDTO,
        level: CommentLevelKey,
        sort: CommentSortDTO,
        nextURL: URL?
    ) async throws -> CommentPageResult {
        started = true
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        return CommentPageResult(items: [], nextURL: nil, isEnd: true)
    }

    func setLiked(_ target: Bool, commentID: String) async throws {}

    func submit(_ snapshot: CommentSubmissionSnapshotDTO) async throws -> CommentDTO {
        throw QAStubError.failed
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor StubOpenedHistory: AnswerOpenedHistory {
    var opened: Set<Int64>
    init(opened: Set<Int64> = []) { self.opened = opened }
    func openedAnswerIDs(questionID: Int64) -> Set<Int64> { opened }
    func markOpened(answerID: Int64, questionID: Int64) { opened.insert(answerID) }
}
