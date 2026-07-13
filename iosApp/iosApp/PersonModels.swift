import Foundation

enum PersonSubscriptionTab: String, CaseIterable, Hashable, Identifiable {
    case followingColumns
    case followingTopics
    case followingQuestions
    case followingCollections

    var id: Self { self }

    var title: String {
        switch self {
        case .followingColumns: return "我订阅的专栏"
        case .followingTopics: return "关注的话题"
        case .followingQuestions: return "关注的问题"
        case .followingCollections: return "关注的收藏夹"
        }
    }
}

extension PersonTab: Identifiable {
    var id: Self { self }

    var title: String {
        switch self {
        case .answers: return "回答"
        case .articles: return "文章"
        case .activities: return "动态"
        case .collections: return "收藏"
        case .questions: return "提问"
        case .pins: return "想法"
        case .columns: return "专栏"
        case .followers: return "粉丝"
        case .following: return "关注"
        case .subscriptions: return "关注订阅"
        }
    }
}

enum PersonContentSort: String, CaseIterable, Hashable, Identifiable {
    case voteups
    case created

    var id: Self { self }

    var title: String {
        switch self {
        case .voteups: return "按热度"
        case .created: return "按时间"
        }
    }
}

struct PersonOfficialBadge: Hashable, Identifiable {
    let title: String
    let description: String
    let iconURL: URL?
    let nightIconURL: URL?
    let destinationURL: URL?
    let typeRaw: String?
    let detailTypeRaw: String?

    var id: String {
        [title, description, iconURL?.absoluteString ?? "", typeRaw ?? "", detailTypeRaw ?? ""]
            .joined(separator: "|")
    }
}

struct PersonProfile: Hashable {
    let memberID: String
    let urlToken: String?
    let displayName: String
    let avatarURL: URL?
    let headline: String
    let primaryOfficialBadge: PersonOfficialBadge?
    let officialBadgeDetails: [PersonOfficialBadge]
    let followerCount: Int
    let followingCount: Int
    let answerCount: Int
    let articleCount: Int
    let isFollowing: Bool
    let isBlocking: Bool
    let memberScopedSearchID: String?

    func replacingFollowState(_ isFollowing: Bool, followerCount: Int) -> Self {
        Self(
            memberID: memberID,
            urlToken: urlToken,
            displayName: displayName,
            avatarURL: avatarURL,
            headline: headline,
            primaryOfficialBadge: primaryOfficialBadge,
            officialBadgeDetails: officialBadgeDetails,
            followerCount: max(0, followerCount),
            followingCount: followingCount,
            answerCount: answerCount,
            articleCount: articleCount,
            isFollowing: isFollowing,
            isBlocking: isBlocking,
            memberScopedSearchID: memberScopedSearchID
        )
    }

    func replacingBlockState(_ isBlocking: Bool) -> Self {
        Self(
            memberID: memberID,
            urlToken: urlToken,
            displayName: displayName,
            avatarURL: avatarURL,
            headline: headline,
            primaryOfficialBadge: primaryOfficialBadge,
            officialBadgeDetails: officialBadgeDetails,
            followerCount: followerCount,
            followingCount: followingCount,
            answerCount: answerCount,
            articleCount: articleCount,
            isFollowing: isFollowing,
            isBlocking: isBlocking,
            memberScopedSearchID: memberScopedSearchID
        )
    }
}

struct PersonDisplayError: Error, Hashable, Identifiable {
    let id = UUID()
    let message: String
}

enum PersonProfileLoadState {
    case idle(provisionalDisplayName: String)
    case loading(previous: PersonProfile?)
    case loaded(PersonProfile)
    case failed(error: PersonDisplayError, previous: PersonProfile?)

    var profile: PersonProfile? {
        switch self {
        case .idle: return nil
        case let .loading(previous): return previous
        case let .loaded(profile): return profile
        case let .failed(_, previous): return previous
        }
    }

    var isInitialLoading: Bool {
        if case .loading(previous: nil) = self { return true }
        return false
    }
}

enum PersonActionState: Equatable {
    case idle
    case inFlight
    case failed(PersonDisplayError)

    var isInFlight: Bool {
        if case .inFlight = self { return true }
        return false
    }
}

enum PersonPageKey: Hashable {
    case main(PersonTab)
    case subscription(PersonSubscriptionTab)
}

enum PersonInitialPageLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(PersonDisplayError)
}

enum PersonNextPageState: Equatable {
    case idle
    case loading
    case failed(PersonDisplayError)
}

struct PersonPageState {
    var initialLoad: PersonInitialPageLoadState = .idle
    var nextPage: PersonNextPageState = .idle
    var isEnd = false
    var items: [PersonPageItem] = []
    var nextURL: URL?

    var canLoadNext: Bool {
        guard case .loaded = initialLoad, !isEnd, nextURL != nil else { return false }
        if case .loading = nextPage { return false }
        return true
    }
}

struct PersonListItemID: Hashable {
    enum Kind: String, Hashable {
        case answer, article, activity, collection, question, pin, column, person, topic, followedQuestion
    }

    let kind: Kind
    let primaryID: String
    let contextID: String?
    let occurrence: Int
}

struct PersonAnswerItem: Hashable {
    let id: PersonListItemID
    let answerID: Int64
    let questionID: Int64
    let questionTitle: String
    let excerpt: String
    let voteUpCount: Int
    let commentCount: Int
}

struct PersonArticleItem: Hashable {
    let id: PersonListItemID
    let articleID: Int64
    let title: String
    let excerpt: String
    let voteUpCount: Int
    let commentCount: Int
}

struct PersonActivityItem: Hashable {
    let id: PersonListItemID
    let title: String
    let summary: String?
    let details: String
    let destination: PersonNavigationIntent?
}

struct PersonCollectionItem: Hashable {
    let id: PersonListItemID
    let collectionID: String
    let title: String
    let contentCount: Int
    let followerCount: Int
}

struct PersonQuestionItem: Hashable {
    let id: PersonListItemID
    let questionID: Int64
    let title: String
    let answerCount: Int
    let followerCount: Int
}

struct PersonPinItem: Hashable {
    let id: PersonListItemID
    let pinID: Int64
    let excerptPlainText: String
    let likeCount: Int
    let commentCount: Int
}

struct PersonColumnItem: Hashable {
    let id: PersonListItemID
    let columnID: String
    let title: String
    let description: String?
    let articleCount: Int
    let followerCount: Int
    let destination: PersonWebRoute?
}

struct PersonListPersonItem: Hashable {
    let id: PersonListItemID
    let route: PersonRoutePayload
    let avatarURL: URL?
    let headline: String
    let primaryOfficialBadge: PersonOfficialBadge?
    let answerCount: Int
    let articleCount: Int
    let followerCount: Int
}

struct PersonTopicItem: Hashable {
    let id: PersonListItemID
    let topicID: String
    let displayName: String
    let avatarURL: URL?
    let destination: PersonWebRoute?
}

struct PersonFollowedQuestionItem: Hashable {
    let id: PersonListItemID
    let rawQuestionID: String
    let title: String
    let questionID: Int64?
}

enum PersonPageItem: Hashable, Identifiable {
    case answer(PersonAnswerItem)
    case article(PersonArticleItem)
    case activity(PersonActivityItem)
    case collection(PersonCollectionItem)
    case question(PersonQuestionItem)
    case pin(PersonPinItem)
    case column(PersonColumnItem)
    case person(PersonListPersonItem)
    case topic(PersonTopicItem)
    case followedQuestion(PersonFollowedQuestionItem)

    var id: PersonListItemID {
        switch self {
        case let .answer(value): return value.id
        case let .article(value): return value.id
        case let .activity(value): return value.id
        case let .collection(value): return value.id
        case let .question(value): return value.id
        case let .pin(value): return value.id
        case let .column(value): return value.id
        case let .person(value): return value.id
        case let .topic(value): return value.id
        case let .followedQuestion(value): return value.id
        }
    }

    func replacingID(_ id: PersonListItemID) -> Self {
        switch self {
        case let .answer(value):
            return .answer(PersonAnswerItem(id: id, answerID: value.answerID, questionID: value.questionID, questionTitle: value.questionTitle, excerpt: value.excerpt, voteUpCount: value.voteUpCount, commentCount: value.commentCount))
        case let .article(value):
            return .article(PersonArticleItem(id: id, articleID: value.articleID, title: value.title, excerpt: value.excerpt, voteUpCount: value.voteUpCount, commentCount: value.commentCount))
        case let .activity(value):
            return .activity(PersonActivityItem(id: id, title: value.title, summary: value.summary, details: value.details, destination: value.destination))
        case let .collection(value):
            return .collection(PersonCollectionItem(id: id, collectionID: value.collectionID, title: value.title, contentCount: value.contentCount, followerCount: value.followerCount))
        case let .question(value):
            return .question(PersonQuestionItem(id: id, questionID: value.questionID, title: value.title, answerCount: value.answerCount, followerCount: value.followerCount))
        case let .pin(value):
            return .pin(PersonPinItem(id: id, pinID: value.pinID, excerptPlainText: value.excerptPlainText, likeCount: value.likeCount, commentCount: value.commentCount))
        case let .column(value):
            return .column(PersonColumnItem(id: id, columnID: value.columnID, title: value.title, description: value.description, articleCount: value.articleCount, followerCount: value.followerCount, destination: value.destination))
        case let .person(value):
            return .person(PersonListPersonItem(id: id, route: value.route, avatarURL: value.avatarURL, headline: value.headline, primaryOfficialBadge: value.primaryOfficialBadge, answerCount: value.answerCount, articleCount: value.articleCount, followerCount: value.followerCount))
        case let .topic(value):
            return .topic(PersonTopicItem(id: id, topicID: value.topicID, displayName: value.displayName, avatarURL: value.avatarURL, destination: value.destination))
        case let .followedQuestion(value):
            return .followedQuestion(PersonFollowedQuestionItem(id: id, rawQuestionID: value.rawQuestionID, title: value.title, questionID: value.questionID))
        }
    }
}

enum PersonArticleKind: String, Hashable {
    case answer
    case article
}

struct PersonArticleRoute: Hashable {
    let id: Int64
    let kind: PersonArticleKind
}

enum PersonWebRouteKind: String, Hashable {
    case profile
    case question
    case pin
    case collection
    case search
    case column
    case topic
    case video
}

struct PersonWebRoute: Hashable {
    let kind: PersonWebRouteKind
    let title: String
    let url: URL

    init?(kind: PersonWebRouteKind, title: String, url: URL) {
        guard Self.allows(url) else { return nil }
        self.kind = kind
        self.title = title
        self.url = url
    }

    private static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return host == "zhihu.com" || host.hasSuffix(".zhihu.com")
    }
}

enum PersonNavigationIntent: Hashable {
    case article(PersonArticleRoute)
    case person(PersonRoutePayload)
    case web(PersonWebRoute)
}

struct PersonPageResult {
    let items: [PersonPageItem]
    let nextURL: URL?
    let isEnd: Bool
}

struct PersonFollowResult {
    let isFollowing: Bool
    let followerCount: Int
}
