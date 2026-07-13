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

    func testRiskControlOnlyAllowsTrustedHttpsZhihuHosts() {
        XCTAssertTrue(RiskControlURLPolicy.allows(URL(string: "https://www.zhihu.com/account/unhuman")!))
        XCTAssertFalse(RiskControlURLPolicy.allows(URL(string: "http://www.zhihu.com/account/unhuman")!))
        XCTAssertFalse(RiskControlURLPolicy.allows(URL(string: "https://zhihu.com.example.com/account/unhuman")!))
    }
}
