import Foundation

enum PersonTab: String, CaseIterable, Hashable {
    case answers
    case articles
    case activities
    case collections
    case questions
    case pins
    case columns
    case followers
    case following
    case subscriptions
}

enum PersonLookupKey: Hashable {
    case memberID(String)
    case urlToken(String)
}

struct PersonRoutePayload: Hashable {
    let memberID: String?
    let urlToken: String?
    let displayName: String
    let initialTab: PersonTab

    init?(
        memberID: String?,
        urlToken: String?,
        displayName: String,
        initialTab: PersonTab = .answers
    ) {
        let normalizedMemberID = Self.normalizedMemberID(memberID)
        let normalizedURLToken = Self.normalized(urlToken)
        guard normalizedMemberID != nil || normalizedURLToken != nil else {
            return nil
        }
        self.memberID = normalizedMemberID
        self.urlToken = normalizedURLToken
        self.displayName = displayName
        self.initialTab = initialTab
    }

    var lookupKey: PersonLookupKey {
        switch (memberID, urlToken) {
        case let (memberID?, _):
            return .memberID(memberID)
        case let (_, urlToken?):
            return .urlToken(urlToken)
        case (nil, nil):
            preconditionFailure("A Person route must have a member ID or URL token")
        }
    }

    private static func normalizedMemberID(_ value: String?) -> String? {
        let value = normalized(value)
        return value == PersonRouteConstants.emptyMemberID ? nil : value
    }

    private static func normalized(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

struct PersonRouteKey: Hashable {
    let routeInstanceID: UUID
    let lookupKey: PersonLookupKey
}

struct PersonRouteEntry: Hashable {
    let key: PersonRouteKey
    let payload: PersonRoutePayload

    init(payload: PersonRoutePayload, routeInstanceID: UUID = UUID()) {
        key = PersonRouteKey(
            routeInstanceID: routeInstanceID,
            lookupKey: payload.lookupKey
        )
        self.payload = payload
    }
}

private enum PersonRouteConstants {
    static let emptyMemberID = "00000000000000000000000000000000"
}
