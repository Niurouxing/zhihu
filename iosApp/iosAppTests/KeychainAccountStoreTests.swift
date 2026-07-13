import Foundation
import XCTest
@testable import iosApp

final class KeychainAccountStoreTests: XCTestCase {
    private var store: KeychainAccountStore!

    override func setUpWithError() throws {
        store = KeychainAccountStore(
            service: "\(KeychainAccountStore.defaultService).tests.\(UUID().uuidString)"
        )
        try store.clear()
    }

    override func tearDownWithError() throws {
        try store.clear()
        store = nil
    }

    func testRoundTripAndOverwrite() throws {
        let first = #"{"cookies":{"z_c0":"first"}}"#
        let second = #"{"cookies":{"z_c0":"second"}}"#

        try store.save(first)
        XCTAssertEqual(try store.load(), first)

        try store.save(second)
        XCTAssertEqual(try store.load(), second)
    }

    func testClearRemovesStoredAccount() throws {
        try store.save(#"{"cookies":{"z_c0":"token"}}"#)

        try store.clear()

        XCTAssertNil(try store.load())
    }

    func testAtomicUpdateTransformsCurrentValue() throws {
        try store.save(#"{"cookies":{"z_c0":"first"}}"#)

        try store.update { current in
            XCTAssertEqual(current, #"{"cookies":{"z_c0":"first"}}"#)
            return #"{"cookies":{"z_c0":"second","d_c0":"device"}}"#
        }

        XCTAssertEqual(
            try store.load(),
            #"{"cookies":{"z_c0":"second","d_c0":"device"}}"#
        )
    }

    func testAtomicCookieWriterPreservesSessionFields() throws {
        try store.save(#"{"cookies":{"z_c0":"token"},"userAgent":"agent","future":true}"#)
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "captcha_session",
                .value: "verified",
                .domain: ".zhihu.com",
                .path: "/",
            ])
        )

        try ZhihuAccountCookieWriter.merge(cookies: [cookie], into: store)

        let stored = try XCTUnwrap(store.load())
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any]
        )
        let cookies = try XCTUnwrap(root["cookies"] as? [String: String])
        XCTAssertEqual(cookies["z_c0"], "token")
        XCTAssertEqual(cookies["captcha_session"], "verified")
        XCTAssertEqual(root["userAgent"] as? String, "agent")
        let future = try XCTUnwrap(root["future"])
        XCTAssertEqual(CFGetTypeID(future as CFTypeRef), CFBooleanGetTypeID())
        XCTAssertEqual(future as? Bool, true)
    }

}
