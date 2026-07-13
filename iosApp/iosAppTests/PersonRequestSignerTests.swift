import Foundation
import XCTest
@testable import iosApp

final class ZhihuRequestSignerTests: XCTestCase {
    func testSignatureIsDeterministicAndIncludesExactQueryOrder() throws {
        let firstURL = try XCTUnwrap(
            URL(string: "https://www.zhihu.com/api/v4/members/token/answers?sort_by=voteups&include=data%5B*%5D.excerpt")
        )
        let reorderedURL = try XCTUnwrap(
            URL(string: "https://www.zhihu.com/api/v4/members/token/answers?include=data%5B*%5D.excerpt&sort_by=voteups")
        )

        let first = ZhihuRequestSignature.zse96(url: firstURL, dc0: "dc0-value", body: nil)
        let repeated = ZhihuRequestSignature.zse96(url: firstURL, dc0: "dc0-value", body: nil)
        let reordered = ZhihuRequestSignature.zse96(url: reorderedURL, dc0: "dc0-value", body: nil)

        XCTAssertEqual(first, repeated)
        XCTAssertTrue(first.hasPrefix("2.0_"))
        XCTAssertNotEqual(first, reordered)
    }

    func testSignatureChangesWhenBodyChanges() throws {
        let url = try XCTUnwrap(URL(string: "https://www.zhihu.com/api/v4/example"))

        XCTAssertNotEqual(
            ZhihuRequestSignature.zse96(url: url, dc0: "dc0-value", body: nil),
            ZhihuRequestSignature.zse96(url: url, dc0: "dc0-value", body: "{}")
        )
    }

    func testRequestSignerAddsHeadersOnlyWithNonEmptyDC0() throws {
        let url = try XCTUnwrap(URL(string: "https://www.zhihu.com/api/v4/example"))
        var unsigned = URLRequest(url: url)
        var signed = URLRequest(url: url)
        let signer = ZhihuRequestSigner()

        signer.applySignature(to: &unsigned, cookies: [:], body: nil)
        signer.applySignature(to: &signed, cookies: ["d_c0": "dc0-value"], body: nil)

        XCTAssertNil(unsigned.value(forHTTPHeaderField: "x-zse-96"))
        XCTAssertEqual(signed.value(forHTTPHeaderField: "x-zse-93"), ZhihuRequestSignature.zse93)
        XCTAssertEqual(signed.value(forHTTPHeaderField: "x-requested-with"), "fetch")
        XCTAssertTrue(signed.value(forHTTPHeaderField: "x-zse-96")?.hasPrefix("2.0_") == true)
    }
}
