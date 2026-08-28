import XCTest
@testable import iosApp

final class ArticleRoutingTests: XCTestCase {
    func testAnswerAndArticleRoutesKeepTheirNativeKinds() {
        XCTAssertEqual(AnswerRouteDTO(contentID: 1, kind: .answer).kind, .answer)
        XCTAssertEqual(AnswerRouteDTO(contentID: 2, kind: .article).kind, .article)
    }

    func testMetadataSettingMovesOnlyDate() {
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: true).dateEdge, .leading)
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: true).ipEdge, .trailing)
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: false).dateEdge, .trailing)
    }

    func testTypedShellRouteRetainsAnswerSource() {
        let route = AnswerRouteDTO(contentID: 7, kind: .answer, questionID: 3, provisionalTitle: "问题")
        XCTAssertEqual(NativeShellRoute.answer(route), .answer(route))
    }

    func testTypedShellRouteRetainsCommentSubject() {
        let route = CommentThreadRouteDTO(subject: .pin(42))
        XCTAssertEqual(NativeShellRoute.comments(route), .comments(route))
    }

    func testSearchFocusRequestTokensAdvanceAndSkipReservedZero() {
        XCTAssertEqual(NativeSearchFocusRequestPolicy.nextToken(after: 0), 1)
        XCTAssertEqual(NativeSearchFocusRequestPolicy.nextToken(after: 41), 42)
        XCTAssertEqual(NativeSearchFocusRequestPolicy.nextToken(after: .max), 1)
    }

    func testSearchFocusRequestConsumesOnlyNewActiveNonzeroToken() {
        XCTAssertTrue(NativeSearchFocusRequestPolicy.shouldConsume(
            .init(token: 2, isActive: true),
            lastConsumedToken: 1
        ))
        XCTAssertFalse(NativeSearchFocusRequestPolicy.shouldConsume(
            .init(token: 2, isActive: true),
            lastConsumedToken: 2
        ))
        XCTAssertFalse(NativeSearchFocusRequestPolicy.shouldConsume(
            .init(token: 2, isActive: false),
            lastConsumedToken: 1
        ))
        XCTAssertFalse(NativeSearchFocusRequestPolicy.shouldConsume(
            .init(token: 0, isActive: true),
            lastConsumedToken: 0
        ))
        XCTAssertFalse(NativeSearchFocusRequestPolicy.shouldConsume(
            .init(token: 2, isActive: true),
            lastConsumedToken: 3
        ))
    }

    func testPushedEmptySearchRequestsFocusWithoutChangingSubmittedRoutes() {
        let memberSearch = SearchRouteDTO(
            restrictedMemberHashID: "member-hash",
            restrictedMemberName: "作者"
        )

        XCTAssertEqual(
            NativeSearchFocusRequestPolicy.pushedRouteRequest(memberSearch),
            NativeSearchFocusRequest(token: 1, isActive: true)
        )
        XCTAssertEqual(
            NativeSearchFocusRequestPolicy.pushedRouteRequest(SearchRouteDTO(query: "热搜词")),
            .inactive
        )
        XCTAssertEqual(
            NativeSearchFocusRequestPolicy.pushedRouteRequest(SearchRouteDTO()),
            NativeSearchFocusRequest(token: 1, isActive: true)
        )
    }

    func testRiskControlOnlyAllowsTrustedHttpsZhihuHosts() {
        XCTAssertTrue(RiskControlURLPolicy.allows(URL(string: "https://www.zhihu.com/account/unhuman")!))
        XCTAssertFalse(RiskControlURLPolicy.allows(URL(string: "http://www.zhihu.com/account/unhuman")!))
        XCTAssertFalse(RiskControlURLPolicy.allows(URL(string: "https://zhihu.com.example.com/account/unhuman")!))
    }
}
