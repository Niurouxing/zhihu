import XCTest
@testable import iosApp

final class NativeLoginLogicTests: XCTestCase {
    func testCompletionURLRequiresExactHomeURL() {
        XCTAssertTrue(LoginCompletionMatcher.matches(
            pageURL: URL(string: "https://www.zhihu.com/"),
            completionURL: "https://www.zhihu.com/"
        ))
        XCTAssertFalse(LoginCompletionMatcher.matches(
            pageURL: URL(string: "https://www.zhihu.com/?next=1"),
            completionURL: "https://www.zhihu.com/"
        ))
    }

    func testSubmissionGateRejectsDuplicateSubmission() throws {
        var gate = LoginSubmissionGate()
        gate.activate()
        let id = try XCTUnwrap(gate.beginSubmission())
        XCTAssertNil(gate.beginSubmission())
        XCTAssertTrue(gate.accepts(id))
        XCTAssertTrue(gate.finish(id))
    }

    func testRiskCookieCodecRequiresStringMap() throws {
        XCTAssertEqual(
            try RiskControlCookieCodec.cookieValues(from: #"{"d_c0":"device"}"#)["d_c0"],
            "device"
        )
        XCTAssertThrowsError(try RiskControlCookieCodec.cookieValues(from: #"{"d_c0":1}"#))
    }

    func testRiskRequestValidatesURLAndCookies() {
        XCTAssertNotNil(RiskControlRequest(
            url: URL(string: "https://www.zhihu.com/account/unhuman")!,
            cookiesJSON: #"{"d_c0":"device"}"#
        ))
        XCTAssertNil(RiskControlRequest(
            url: URL(string: "https://example.com/account/unhuman")!,
            cookiesJSON: #"{"d_c0":"device"}"#
        ))
    }

    func testQrAuthorizationUsesZhihuScanLoginPrefix() {
        XCTAssertNotNil(QrAuthorizationURLPolicy.validatedURL(
            from: "https://www.zhihu.com/account/scan/login/token"
        ))
        XCTAssertNil(QrAuthorizationURLPolicy.validatedURL(from: "https://example.com/login/token"))
    }

    func testSystemExternalLinksAreValidHTTPSURLs() {
        XCTAssertTrue(SystemExternalLink.allCases.allSatisfy { $0.validatedURL?.scheme == "https" })
        XCTAssertEqual(SystemExternalLink.sourceCode.validatedURL?.host, "github.com")
        XCTAssertTrue(SystemExternalLink.openSourceLicense.destination.hasSuffix("/blob/main/LICENSE"))
    }
}
