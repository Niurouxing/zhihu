import Foundation

enum HomeRecommendationSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case app
    case web

    var id: Self { self }

    var title: String {
        switch self {
        case .app: return "App 接口"
        case .web: return "Web 接口"
        }
    }
}

struct HomeRecommendationRefreshConfiguration: Equatable, Sendable {
    static let targetItemRange = 6 ... 20
    static let requestLimit = 10
    static let defaultValue = HomeRecommendationRefreshConfiguration(
        source: .app,
        targetItemCount: 20
    )

    let source: HomeRecommendationSource
    let targetItemCount: Int

    init(source: HomeRecommendationSource, targetItemCount: Int) {
        self.source = source
        self.targetItemCount = min(
            max(targetItemCount, Self.targetItemRange.lowerBound),
            Self.targetItemRange.upperBound
        )
    }
}

enum HomeRecommendationRefreshIntent: Equatable, Sendable {
    case pull
    case automatic
    case returnToTop
    case sourceChanged
    case retry

    var replacesActiveRefresh: Bool {
        switch self {
        case .returnToTop, .sourceChanged:
            return true
        case .pull, .automatic, .retry:
            return false
        }
    }
}

enum HomeRecommendationRefreshOutcome: Equatable, Sendable {
    case published
    case publishedPartially
    case ignored
    case noContent
    case failed
    case cancelled
}

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
