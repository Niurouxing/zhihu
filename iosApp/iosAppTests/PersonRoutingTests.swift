import XCTest
@testable import iosApp

@MainActor
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

    func testEveryPersonIntentMapsToItsNativeDestination() throws {
        let payload = try XCTUnwrap(PersonRoutePayload(
            memberID: "member",
            urlToken: "token",
            displayName: "用户"
        ))
        let webRoute = try XCTUnwrap(PersonWebRoute(
            kind: .topic,
            title: "话题",
            url: URL(string: "https://www.zhihu.com/topic/7")!
        ))
        let connectionPayload = try XCTUnwrap(PersonRoutePayload(
            memberID: "member",
            urlToken: "token",
            displayName: "用户",
            initialTab: .followers
        ))
        let connections = try XCTUnwrap(PersonConnectionsRoute(person: connectionPayload))
        let search = SearchRouteDTO(
            restrictedMemberHashID: "member-hash",
            restrictedMemberName: "用户"
        )

        XCTAssertEqual(
            PersonNavigationIntent.article(.init(id: 1, kind: .answer)).nativeShellRoute,
            .answer(.init(contentID: 1, kind: .answer))
        )
        XCTAssertEqual(
            PersonNavigationIntent.article(.init(id: 2, kind: .article)).nativeShellRoute,
            .answer(.init(contentID: 2, kind: .article))
        )
        XCTAssertEqual(PersonNavigationIntent.question(3).nativeShellRoute, .question(.init(questionID: 3)))
        XCTAssertEqual(PersonNavigationIntent.pin(4).nativeShellRoute, .pin(.init(pinID: 4)))
        XCTAssertEqual(PersonNavigationIntent.collection("5").nativeShellRoute, .collectionContent("5"))
        XCTAssertEqual(PersonNavigationIntent.person(payload).nativeShellRoute, .person(payload))
        XCTAssertEqual(PersonNavigationIntent.connections(connections).nativeShellRoute, .personConnections(connections))
        XCTAssertEqual(PersonNavigationIntent.search(search).nativeShellRoute, .search(search))
        XCTAssertEqual(PersonNavigationIntent.web(webRoute).nativeShellRoute, .personWeb(webRoute))
    }

    func testPersonDestinationsStayInTheirSourceTabNavigationStack() throws {
        let payload = try XCTUnwrap(PersonRoutePayload(
            memberID: "member",
            urlToken: "token",
            displayName: "用户"
        ))
        let navigation = NativeTabNavigationState()
        let person = NativeShellRoute.person(payload)
        let answer = PersonNavigationIntent.article(.init(id: 42, kind: .answer)).nativeShellRoute
        let pin = PersonNavigationIntent.pin(11).nativeShellRoute

        navigation.navigate(to: person, in: .home)
        navigation.navigate(to: answer, in: .home)
        navigation.navigate(to: pin, in: .hot)

        XCTAssertEqual(navigation.binding(for: .home).wrappedValue, [person, answer])
        XCTAssertEqual(navigation.binding(for: .hot).wrappedValue, [pin])
        XCTAssertTrue(navigation.binding(for: .account).wrappedValue.isEmpty)
    }
}
