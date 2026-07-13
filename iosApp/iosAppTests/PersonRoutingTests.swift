import XCTest
@testable import iosApp

final class PersonRoutingTests: XCTestCase {
    func testRoutePayloadNormalizesIdentityAndRejectsEmptyIdentity() throws {
        let payload = try XCTUnwrap(PersonRoutePayload(
            memberID: "  member-id  ",
            urlToken: " token ",
            displayName: "Alice",
            initialTab: .activities
        ))
        XCTAssertEqual(payload.memberID, "member-id")
        XCTAssertEqual(payload.urlToken, "token")
        XCTAssertNil(PersonRoutePayload(memberID: "", urlToken: " ", displayName: ""))
    }

    func testRouteEntriesHaveIndependentNavigationIdentity() throws {
        let payload = try XCTUnwrap(PersonRoutePayload(memberID: "member", urlToken: nil, displayName: "A"))
        XCTAssertNotEqual(PersonRouteEntry(payload: payload).key, PersonRouteEntry(payload: payload).key)
    }

    func testPersonWebRouteRejectsUntrustedHost() {
        XCTAssertNotNil(PersonWebRoute(
            kind: .profile,
            title: "A",
            url: URL(string: "https://www.zhihu.com/people/a")!
        ))
        XCTAssertNil(PersonWebRoute(
            kind: .profile,
            title: "A",
            url: URL(string: "https://zhihu.com.example.com/people/a")!
        ))
    }
}
