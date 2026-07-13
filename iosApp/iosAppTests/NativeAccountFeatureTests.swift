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
}
