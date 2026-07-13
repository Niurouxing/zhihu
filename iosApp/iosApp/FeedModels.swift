import Foundation

enum FeedItemKind: String, Hashable, Sendable {
    case answer
    case article
    case question
    case pin
    case video
}

struct FeedItemID: Hashable, Sendable {
    let kind: FeedItemKind
    let contentID: String
}

struct FeedAuthorDTO: Hashable, Sendable {
    let memberID: String
    let urlToken: String?
    let displayName: String
    let avatarURL: URL?
    let headline: String
}

enum FeedItemRoute: Hashable, Sendable {
    case answer(answerID: Int64, questionID: Int64, questionTitle: String)
    case article(articleID: Int64, title: String)
    case question(questionID: Int64, title: String)
    case pin(pinID: Int64)
    case video(videoID: Int64)
}

struct FeedItemDTO: Identifiable, Hashable, Sendable {
    let id: FeedItemID
    let kind: FeedItemKind
    let title: String
    let summary: String?
    let details: String
    let sourceLabel: String?
    let author: FeedAuthorDTO?
    let thumbnailURL: URL?
    let route: FeedItemRoute
}

struct FeedPageDTO: Sendable {
    let items: [FeedItemDTO]
    let nextURL: URL?
    let isEnd: Bool
}

struct SearchRouteDTO: Hashable, Sendable {
    let query: String
    let restrictedMemberHashID: String?
    let restrictedMemberName: String?

    init(
        query: String = "",
        restrictedMemberHashID: String? = nil,
        restrictedMemberName: String? = nil
    ) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.restrictedMemberHashID = restrictedMemberHashID?.trimmedNonEmpty
        self.restrictedMemberName = restrictedMemberName?.trimmedNonEmpty
    }

    var isMemberRestricted: Bool { restrictedMemberHashID != nil }
}

enum SearchSort: String, CaseIterable, Identifiable, Sendable {
    case relevance
    case latest
    case mostVoted

    var id: Self { self }

    var title: String {
        switch self {
        case .relevance: return "综合排序"
        case .latest: return "最新发布"
        case .mostVoted: return "最多赞同"
        }
    }

    var requestValue: String? {
        switch self {
        case .relevance: return nil
        case .latest: return "created_time"
        case .mostVoted: return "upvoted_count"
        }
    }
}

enum SearchContentType: String, CaseIterable, Identifiable, Sendable {
    case all
    case answer
    case article
    case video

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部内容"
        case .answer: return "回答"
        case .article: return "文章"
        case .video: return "视频"
        }
    }

    var requestValue: String? {
        switch self {
        case .all: return nil
        case .answer: return "answer"
        case .article: return "article"
        case .video: return "zvideo"
        }
    }
}

enum SearchTimeRange: String, CaseIterable, Identifiable, Sendable {
    case all
    case day
    case week
    case month
    case threeMonths
    case halfYear
    case year

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "不限时间"
        case .day: return "一天内"
        case .week: return "一周内"
        case .month: return "一个月内"
        case .threeMonths: return "三个月内"
        case .halfYear: return "半年内"
        case .year: return "一年内"
        }
    }

    var requestValue: String? {
        switch self {
        case .all: return nil
        case .day: return "a_day"
        case .week: return "a_week"
        case .month: return "a_month"
        case .threeMonths: return "three_months"
        case .halfYear: return "half_a_year"
        case .year: return "a_year"
        }
    }
}

struct SearchCriteria: Hashable, Sendable {
    let query: String
    let restrictedMemberHashID: String?
    let sort: SearchSort
    let contentType: SearchContentType
    let timeRange: SearchTimeRange

    var hasActiveFilter: Bool {
        sort != .relevance || contentType != .all || timeRange != .all
    }
}

struct SearchSuggestionDTO: Identifiable, Hashable, Sendable {
    let query: String
    let popularityText: String?
    let label: String?

    var id: String { query }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
