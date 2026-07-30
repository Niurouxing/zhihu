import Foundation
import Security
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

    func testLegacyVerifiedSessionMigratesIntoAccountVault() throws {
        let legacy = verifiedSession(
            id: "alice-id",
            name: "Alice",
            token: "alice",
            cookie: "alice-secret"
        )
        try writeLegacyRaw(legacy)

        XCTAssertEqual(try store.load(), legacy)
        XCTAssertEqual(try store.currentAccountID(), "alice-id")
        XCTAssertEqual(
            try store.listAccounts(),
            [NativeSavedAccountSummary(
                id: "alice-id",
                name: "Alice",
                urlToken: "alice",
                avatarURL: URL(string: "https://pic.zhimg.com/alice-id.jpg")
            )]
        )

        let reloaded = KeychainAccountStore(service: store.service)
        XCTAssertEqual(try reloaded.load(), legacy)
        XCTAssertEqual(try reloaded.currentAccountID(), "alice-id")
    }

    func testVerifiedSessionsCanBeListedAndSwitchedWithoutExposingCookies() throws {
        let alice = verifiedSession(id: "alice-id", name: "Alice", token: "alice", cookie: "alice-secret")
        let bob = verifiedSession(id: "bob-id", name: "Bob", token: "bob", cookie: "bob-secret")
        try store.save(alice)
        try store.save(bob)

        XCTAssertEqual(try store.currentAccountID(), "bob-id")
        XCTAssertEqual(try store.listAccounts().map(\.id), ["alice-id", "bob-id"])
        XCTAssertFalse(String(describing: try store.listAccounts()).contains("secret"))

        try store.switchAccount(to: "alice-id")

        XCTAssertEqual(try store.currentAccountID(), "alice-id")
        XCTAssertEqual(try store.load(), alice)
    }

    func testUpdatingCurrentSessionDoesNotMutateAnotherAccount() throws {
        let alice = verifiedSession(id: "alice-id", name: "Alice", token: "alice", cookie: "alice-secret")
        let bob = verifiedSession(id: "bob-id", name: "Bob", token: "bob", cookie: "bob-secret")
        try store.save(alice)
        try store.save(bob)

        try store.update { current in
            try NativeAccountCodec.merging(
                profile: NativeAccountIdentity(
                    id: "bob-id",
                    name: "Bob Updated",
                    urlToken: "bob",
                    userType: "people",
                    avatarURL: nil
                ),
                into: current
            )
        }
        try store.switchAccount(to: "alice-id")

        XCTAssertEqual(try store.load(), alice)
        XCTAssertEqual(try store.listAccounts().first(where: { $0.id == "bob-id" })?.name, "Bob Updated")
    }

    func testDeleteIsLimitedToNonCurrentAccount() throws {
        try store.save(verifiedSession(id: "alice-id", name: "Alice", token: "alice", cookie: "alice-secret"))
        try store.save(verifiedSession(id: "bob-id", name: "Bob", token: "bob", cookie: "bob-secret"))

        XCTAssertThrowsError(try store.deleteAccount("bob-id")) {
            XCTAssertEqual($0 as? MultipleAccountStoreError, .cannotDeleteCurrentAccount)
        }

        try store.deleteAccount("alice-id")

        XCTAssertEqual(try store.listAccounts().map(\.id), ["bob-id"])
        XCTAssertEqual(try store.currentAccountID(), "bob-id")
    }

    func testClearingCurrentAccountPreservesOtherSavedSessions() throws {
        let alice = verifiedSession(id: "alice-id", name: "Alice", token: "alice", cookie: "alice-secret")
        try store.save(alice)
        try store.save(verifiedSession(id: "bob-id", name: "Bob", token: "bob", cookie: "bob-secret"))

        try store.clearCurrentAccount()

        XCTAssertNil(try store.load())
        XCTAssertNil(try store.currentAccountID())
        XCTAssertEqual(try store.listAccounts().map(\.id), ["alice-id"])

        try store.switchAccount(to: "alice-id")
        XCTAssertEqual(try store.load(), alice)
    }

    private func verifiedSession(
        id: String,
        name: String,
        token: String,
        cookie: String
    ) -> String {
        """
        {"login":true,"username":"\(name)","cookies":{"d_c0":"device","z_c0":"\(cookie)"},"profile":{"id":"\(id)","name":"\(name)","urlToken":"\(token)","userType":"people","avatarUrl":"https://pic.zhimg.com/\(id).jpg"}}
        """
    }

    private func writeLegacyRaw(_ value: String) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecAttrAccount as String: store.account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)
    }
}
