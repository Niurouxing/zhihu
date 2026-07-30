import XCTest
@testable import iosApp

@MainActor
final class NativeAccountFeatureTests: XCTestCase {
    func testCodecReadsCurrentKeychainSessionShape() throws {
        let account = try NativeAccountCodec.decode(
            """
            {
              "login": true,
              "username": "Alice",
              "cookies": {"d_c0": "token"},
              "profile": {
                "id": "member-id",
                "name": "Alice",
                "urlToken": "alice",
                "userType": "people",
                "avatarUrl": "https://pic.zhimg.com/avatar.jpg"
              }
            }
            """
        )

        XCTAssertTrue(account.isLoggedIn)
        XCTAssertEqual(account.identity?.urlToken, "alice")
        XCTAssertEqual(account.identity?.avatarURL?.host, "pic.zhimg.com")
    }

    func testProfileMergePreservesCookiesAndUnknownFields() throws {
        let profile = NativeAccountIdentity(
            id: "new-id",
            name: "New Name",
            urlToken: "new-token",
            userType: "people",
            avatarURL: nil
        )
        let merged = try NativeAccountCodec.merging(
            profile: profile,
            into: "{\"login\":true,\"cookies\":{\"d_c0\":\"secret\"},\"future\":7}"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])

        XCTAssertEqual((root["cookies"] as? [String: String])?["d_c0"], "secret")
        XCTAssertEqual(root["future"] as? Int, 7)
        XCTAssertEqual((root["profile"] as? [String: Any])?["name"] as? String, "New Name")
    }

    func testSignOutPublishesSignedOutOnlyAfterRepositorySucceeds() {
        var didSignOut = false
        let repository = NativeAccountRepository(
            load: { NativeStoredAccount(isLoggedIn: false, username: "", identity: nil) },
            refreshProfile: { NativeStoredAccount(isLoggedIn: false, username: "", identity: nil) },
            signOut: { didSignOut = true }
        )
        let store = NativeAccountStore(repository: repository)

        store.signOut()

        XCTAssertTrue(didSignOut)
        XCTAssertEqual(store.state, .signedOut)
    }

    func testSwitchAccountPublishesNewIdentityAndCurrentStableID() {
        let alice = Self.accountIdentity(id: "alice-id", name: "Alice", token: "alice")
        let bob = Self.accountIdentity(id: "bob-id", name: "Bob", token: "bob")
        var currentID = alice.id
        let summaries = [alice, bob].map(Self.savedSummary)
        let repository = NativeAccountRepository(
            load: { Self.storedAccount(alice) },
            refreshProfile: { Self.storedAccount(alice) },
            signOut: {},
            listAccounts: { summaries },
            currentAccountID: { currentID },
            switchAccount: { targetID in
                currentID = targetID
                return Self.storedAccount(targetID == bob.id ? bob : alice)
            }
        )
        let store = NativeAccountStore(repository: repository)
        store.reloadFromKeychain()

        store.switchAccount(to: bob.id)

        XCTAssertEqual(store.state, .signedIn(bob))
        XCTAssertEqual(store.currentAccountID, bob.id)
        XCTAssertEqual(store.accounts.map(\.id), [alice.id, bob.id])
    }

    func testDeleteAccountCannotAffectCurrentIdentity() {
        let alice = Self.accountIdentity(id: "alice-id", name: "Alice", token: "alice")
        let bob = Self.accountIdentity(id: "bob-id", name: "Bob", token: "bob")
        var summaries = [Self.savedSummary(alice), Self.savedSummary(bob)]
        let repository = NativeAccountRepository(
            load: { Self.storedAccount(alice) },
            refreshProfile: { Self.storedAccount(alice) },
            signOut: {},
            listAccounts: { summaries },
            currentAccountID: { alice.id },
            deleteAccount: { targetID in
                summaries.removeAll { $0.id == targetID }
            }
        )
        let store = NativeAccountStore(repository: repository)
        store.reloadFromKeychain()

        store.deleteAccount(bob.id)
        store.deleteAccount(alice.id)

        XCTAssertEqual(store.state, .signedIn(alice))
        XCTAssertEqual(store.accounts.map(\.id), [alice.id])
        XCTAssertEqual(store.currentAccountID, alice.id)
    }

    private static func accountIdentity(id: String, name: String, token: String) -> NativeAccountIdentity {
        NativeAccountIdentity(
            id: id,
            name: name,
            urlToken: token,
            userType: "people",
            avatarURL: URL(string: "https://pic.zhimg.com/\(id).jpg")
        )
    }

    private static func savedSummary(_ identity: NativeAccountIdentity) -> NativeSavedAccountSummary {
        NativeSavedAccountSummary(
            id: identity.id,
            name: identity.name,
            urlToken: identity.urlToken,
            avatarURL: identity.avatarURL
        )
    }

    private static func storedAccount(_ identity: NativeAccountIdentity) -> NativeStoredAccount {
        NativeStoredAccount(isLoggedIn: true, username: identity.name, identity: identity)
    }
}
