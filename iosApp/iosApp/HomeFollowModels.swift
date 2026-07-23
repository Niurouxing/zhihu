import Foundation

struct FollowingUserDTO: Identifiable, Hashable, Sendable {
    let id: String
    let urlToken: String
    let displayName: String
    let avatarURL: URL?
    let unreadCount: Int

    var personRoute: PersonRoutePayload? {
        PersonRoutePayload(
            memberID: id,
            urlToken: urlToken,
            displayName: displayName,
            initialTab: .activities
        )
    }
}

enum FollowSection: String, CaseIterable, Identifiable, Sendable {
    case recommendations
    case moments

    var id: Self { self }

    var title: String {
        switch self {
        case .recommendations: return "推荐"
        case .moments: return "动态"
        }
    }
}

struct FollowPageState: Sendable {
    var items: [FeedItemDTO] = []
    var nextURL: URL?
    var isEnd = false
    var hasLoaded = false
    var isLoading = false
    var errorMessage: String?

    var canLoadMore: Bool { hasLoaded && !isEnd && nextURL != nil && !isLoading }
    var hasNextPage: Bool { hasLoaded && !isEnd && nextURL != nil }
    var nextPageLoadID: String? { nextURL?.absoluteString }
}
