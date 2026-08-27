import Foundation
import Combine

enum FeedItemKind: String, Codable, Hashable, Sendable {
    case answer
    case article
    case question
    case pin
    case video
}

struct FeedItemID: Codable, Hashable, Sendable {
    let kind: FeedItemKind
    let contentID: String
}

struct FeedAuthorDTO: Codable, Hashable, Sendable {
    let memberID: String
    let urlToken: String?
    let displayName: String
    let avatarURL: URL?
    let headline: String
}

struct BlockedQuestionAuthor: Codable, Hashable, Identifiable, Sendable {
    let memberID: String
    let urlToken: String?
    let displayName: String
    let avatarURL: URL?
    let createdAt: Date

    var id: String { memberID }
}

@MainActor
final class QuestionAuthorBlocklistStore: ObservableObject {
    @Published private(set) var entries: [BlockedQuestionAuthor]

    private let defaults: UserDefaults
    private let persistenceKey: String

    init(
        defaults: UserDefaults = .standard,
        persistenceKey: String = "blockedQuestionAuthors.v1"
    ) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        entries = Self.load(defaults: defaults, persistenceKey: persistenceKey)
    }

    var blockedMemberIDs: Set<String> {
        Set(entries.map(\.memberID))
    }

    func isBlocked(memberID: String) -> Bool {
        blockedMemberIDs.contains(memberID)
    }

    func block(_ author: FeedAuthorDTO, now: Date = Date()) {
        let memberID = author.memberID.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = author.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !memberID.isEmpty, !displayName.isEmpty else { return }
        let entry = BlockedQuestionAuthor(
            memberID: memberID,
            urlToken: author.urlToken,
            displayName: displayName,
            avatarURL: author.avatarURL,
            createdAt: now
        )
        entries.removeAll { $0.memberID == entry.memberID }
        entries.insert(entry, at: 0)
        persist()
    }

    func unblock(memberID: String) {
        let previousCount = entries.count
        entries.removeAll { $0.memberID == memberID }
        guard entries.count != previousCount else { return }
        persist()
    }

    private static func load(defaults: UserDefaults, persistenceKey: String) -> [BlockedQuestionAuthor] {
        guard let data = defaults.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([BlockedQuestionAuthor].self, from: data)
        else { return [] }

        var seen: Set<String> = []
        return decoded
            .filter { !$0.memberID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0.memberID).inserted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: persistenceKey)
    }
}

struct FeedMediaDTO: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case image
        case animatedImage
    }

    let id: String
    let kind: Kind
    let sourceURL: URL
    let thumbnailURL: URL?
    let pixelWidth: Int?
    let pixelHeight: Int?

    var previewURL: URL { thumbnailURL ?? sourceURL }
    var isAnimated: Bool { kind == .animatedImage }
}

enum FeedMediaCarouselPresentationPolicy {
    /// Two images are shown in full. Longer galleries expose part of a third
    /// tile so horizontal browsing is discoverable without adding chrome.
    static let partiallyVisibleItemCount = 2.4

    static func simultaneousVisibleItemCount(totalItems: Int) -> Double {
        guard totalItems > 0 else { return 0 }
        return totalItems <= 2 ? Double(totalItems) : partiallyVisibleItemCount
    }

    static func itemWidth(
        availableWidth: Double,
        spacing: Double,
        totalItems: Int
    ) -> Double {
        let visibleItems = simultaneousVisibleItemCount(totalItems: totalItems)
        guard availableWidth > 0, visibleItems > 0 else { return 0 }

        let visibleSpacingCount = max(0, ceil(visibleItems) - 1)
        let availableTileWidth = max(0, availableWidth - spacing * visibleSpacingCount)
        return availableTileWidth / visibleItems
    }
}

enum FeedSingleImageLayout: Equatable, Sendable {
    case fit
    case crop(containerAspectRatio: Double)

    var cropsContent: Bool {
        if case .crop = self { return true }
        return false
    }
}

enum FeedSingleImagePresentationPolicy {
    /// Landscape images can expand horizontally without making a card too
    /// tall, so they are shown in full up to 3:1. Portrait images are bounded
    /// at 3:4: taller phone screenshots remain useful previews instead of
    /// expanding one feed item to nearly the height of the entire screen.
    static let minimumFullyVisibleAspectRatio = 3.0 / 4.0
    static let maximumFullyVisibleAspectRatio = 3.0

    static func layout(pixelWidth: Int?, pixelHeight: Int?) -> FeedSingleImageLayout {
        guard let pixelWidth,
              let pixelHeight,
              pixelWidth > 0,
              pixelHeight > 0
        else {
            return .crop(containerAspectRatio: minimumFullyVisibleAspectRatio)
        }

        let aspectRatio = Double(pixelWidth) / Double(pixelHeight)
        if aspectRatio < minimumFullyVisibleAspectRatio {
            return .crop(containerAspectRatio: minimumFullyVisibleAspectRatio)
        }
        if aspectRatio > maximumFullyVisibleAspectRatio {
            return .crop(containerAspectRatio: maximumFullyVisibleAspectRatio)
        }
        return .fit
    }
}

enum FeedTextPresentationPolicy {
    static func compact(_ text: String?) -> String? {
        guard let text else { return nil }
        let compacted = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return compacted.isEmpty ? nil : compacted
    }
}

enum NativeVideoContentType: String, Codable, Hashable, Sendable {
    case answer
    case article
    case question
    case zvideo

    var sceneCode: String {
        "answer_detail_web"
    }
}

struct NativeVideoRouteDTO: Codable, Hashable, Sendable {
    let contentID: Int64
    let videoID: Int64
    let contentType: NativeVideoContentType
    let title: String
    let thumbnailURL: URL?
    let playbackURL: URL?
    let webURL: URL?

    init(
        contentID: Int64,
        videoID: Int64? = nil,
        contentType: NativeVideoContentType,
        title: String = "视频",
        thumbnailURL: URL? = nil,
        playbackURL: URL? = nil,
        webURL: URL? = nil
    ) {
        self.contentID = contentID
        self.videoID = videoID ?? contentID
        self.contentType = contentType
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "视频" : title
        self.thumbnailURL = thumbnailURL
        self.playbackURL = playbackURL
        self.webURL = webURL
    }
}

enum FeedItemRoute: Codable, Hashable, Sendable {
    case answer(answerID: Int64, questionID: Int64?, questionTitle: String)
    case article(articleID: Int64, title: String)
    case question(questionID: Int64, title: String)
    case pin(pinID: Int64)
    case video(NativeVideoRouteDTO)
}

struct FeedItemDTO: Codable, Identifiable, Hashable, Sendable {
    let id: FeedItemID
    let kind: FeedItemKind
    let title: String
    let summary: String?
    let details: String
    let sourceLabel: String?
    let author: FeedAuthorDTO?
    /// The author who asked the question. For answer cards this deliberately
    /// comes from `question.author`, never from the answer author.
    let questionAuthor: FeedAuthorDTO?
    let thumbnailURL: URL?
    let thumbnailPixelWidth: Int?
    let thumbnailPixelHeight: Int?
    let media: [FeedMediaDTO]
    let route: FeedItemRoute

    init(
        id: FeedItemID,
        kind: FeedItemKind,
        title: String,
        summary: String?,
        details: String,
        sourceLabel: String?,
        author: FeedAuthorDTO?,
        questionAuthor: FeedAuthorDTO? = nil,
        thumbnailURL: URL?,
        thumbnailPixelWidth: Int? = nil,
        thumbnailPixelHeight: Int? = nil,
        media: [FeedMediaDTO] = [],
        route: FeedItemRoute
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.details = details
        self.sourceLabel = sourceLabel
        self.author = author
        self.questionAuthor = questionAuthor
        self.thumbnailURL = thumbnailURL
        self.thumbnailPixelWidth = thumbnailPixelWidth
        self.thumbnailPixelHeight = thumbnailPixelHeight
        self.media = media
        self.route = route
    }
}

enum FeedQuestionAuthorVisibilityPolicy {
    static func isVisible(
        _ item: FeedItemDTO,
        blockedMemberIDs: Set<String>
    ) -> Bool {
        guard let memberID = item.questionAuthor?.memberID else {
            // Missing question metadata is not evidence that an item is blocked.
            return true
        }
        return !blockedMemberIDs.contains(memberID)
    }

    static func visibleItems(
        from items: [FeedItemDTO],
        blockedMemberIDs: Set<String>
    ) -> [FeedItemDTO] {
        items.filter { isVisible($0, blockedMemberIDs: blockedMemberIDs) }
    }
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
