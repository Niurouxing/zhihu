import Foundation

enum QAContentKind: String, Hashable, Sendable {
    case answer
    case article
}

struct QuestionRouteDTO: Hashable, Sendable {
    let questionID: Int64
    let provisionalTitle: String

    init(questionID: Int64, provisionalTitle: String = "") {
        self.questionID = questionID
        self.provisionalTitle = provisionalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AnswerRouteDTO: Hashable, Sendable {
    let contentID: Int64
    let kind: QAContentKind
    let questionID: Int64?
    let provisionalTitle: String
    let source: AnswerPageSourceDTO?

    init(
        contentID: Int64,
        kind: QAContentKind,
        questionID: Int64? = nil,
        provisionalTitle: String = "",
        source: AnswerPageSourceDTO? = nil
    ) {
        self.contentID = contentID
        self.kind = kind
        self.questionID = questionID
        self.provisionalTitle = provisionalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
    }
}

struct AnswerPageSourceDTO: Hashable, Sendable {
    let sourceName: String
    let questionID: Int64
    let order: QuestionAnswerSort
    let orderedAnswers: [AnswerPreviewDTO]
    let selectedAnswerID: Int64
    let nextURL: URL?

    init(
        sourceName: String = "此问题",
        questionID: Int64,
        order: QuestionAnswerSort,
        orderedAnswers: [AnswerPreviewDTO],
        selectedAnswerID: Int64,
        nextURL: URL?
    ) {
        self.sourceName = sourceName
        self.questionID = questionID
        self.order = order
        self.orderedAnswers = orderedAnswers
        self.selectedAnswerID = selectedAnswerID
        self.nextURL = nextURL
    }
}

enum QuestionAnswerSort: String, CaseIterable, Identifiable, Hashable, Sendable {
    case `default`
    case updated

    var id: Self { self }
    var title: String { self == .default ? "默认" : "最新" }
}

struct QAAuthorDTO: Hashable, Sendable {
    let memberID: String
    let urlToken: String
    let displayName: String
    let headline: String
    let avatarURL: URL?

    var personIntent: QANavigationIntent? {
        guard !memberID.isEmpty || !urlToken.isEmpty else { return nil }
        guard let payload = PersonRoutePayload(
            memberID: memberID,
            urlToken: urlToken,
            displayName: displayName,
            initialTab: .answers
        ) else { return nil }
        return .person(payload)
    }
}

struct QuestionDTO: Hashable, Sendable {
    let id: Int64
    let title: String
    let detailHTML: String
    let detailBlocks: [QABodyBlock]
    let answerCount: Int
    let visitCount: Int
    let commentCount: Int
    let followerCount: Int
    let isFollowing: Bool
    let author: QAAuthorDTO?
    let topics: [QATopicDTO]

    func replacingFollow(isFollowing: Bool, followerCount: Int) -> Self {
        Self(
            id: id,
            title: title,
            detailHTML: detailHTML,
            detailBlocks: detailBlocks,
            answerCount: answerCount,
            visitCount: visitCount,
            commentCount: commentCount,
            followerCount: max(0, followerCount),
            isFollowing: isFollowing,
            author: author,
            topics: topics
        )
    }
}

struct QATopicDTO: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL?
}

struct AnswerPreviewDTO: Identifiable, Hashable, Sendable {
    let answerID: Int64
    let questionID: Int64
    let questionTitle: String
    let author: QAAuthorDTO
    let excerpt: String
    let voteUpCount: Int
    let commentCount: Int

    var id: Int64 { answerID }
}

struct QuestionAnswerPageDTO: Sendable {
    let items: [AnswerPreviewDTO]
    let nextURL: URL?
    let isEnd: Bool
}

enum QAVoteState: String, Hashable, Sendable {
    case neutral
    case up
    case down
}

enum QAFavoriteState: Hashable, Sendable {
    case unknown
    case notFavorited
    case favorited
}

enum QAMetadataEdge: Hashable, Sendable {
    case leading
    case trailing
}

struct QAMetadataPlacement: Hashable, Sendable {
    let dateEdge: QAMetadataEdge
    let ipEdge: QAMetadataEdge = .trailing

    init(pinAnswerDate: Bool) {
        dateEdge = pinAnswerDate ? .leading : .trailing
    }
}

struct QACollectionDTO: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let isFavorited: Bool
}

struct QAEndorsementDTO: Identifiable, Hashable, Sendable {
    let text: String
    let actionURL: URL?
    let leadingIconKey: String?

    var id: String { "\(text)|\(actionURL?.absoluteString ?? "")|\(leadingIconKey ?? "")" }
}

struct QAAttachmentVideoDTO: Hashable, Sendable {
    let videoID: Int64
    let thumbnailURL: URL?
    let destinationURL: URL?
    let playbackURL: URL?

    init(
        videoID: Int64,
        thumbnailURL: URL?,
        destinationURL: URL?,
        playbackURL: URL? = nil
    ) {
        self.videoID = videoID
        self.thumbnailURL = thumbnailURL
        self.destinationURL = destinationURL
        self.playbackURL = playbackURL
    }
}

struct AnswerDTO: Hashable, Sendable {
    let route: AnswerRouteDTO
    let title: String
    let questionID: Int64?
    let author: QAAuthorDTO
    let blocks: [QABodyBlock]
    let attachment: QAAttachmentVideoDTO?
    let sourceURL: URL
    let voteUpCount: Int
    let favoriteCount: Int
    let commentCount: Int
    let voteState: QAVoteState
    let favoriteState: QAFavoriteState
    let createdTimeSeconds: Int64
    let updatedTimeSeconds: Int64
    let ipLocation: String?
    let invitationPreface: String?
    let endorsements: [QAEndorsementDTO]

    func replacingVote(_ state: QAVoteState, count: Int) -> Self {
        Self(
            route: route, title: title, questionID: questionID, author: author, blocks: blocks,
            attachment: attachment, sourceURL: sourceURL, voteUpCount: max(0, count),
            favoriteCount: favoriteCount, commentCount: commentCount, voteState: state,
            favoriteState: favoriteState, createdTimeSeconds: createdTimeSeconds,
            updatedTimeSeconds: updatedTimeSeconds, ipLocation: ipLocation,
            invitationPreface: invitationPreface, endorsements: endorsements
        )
    }

    func replacingFavorite(_ state: QAFavoriteState, count: Int) -> Self {
        Self(
            route: route, title: title, questionID: questionID, author: author, blocks: blocks,
            attachment: attachment, sourceURL: sourceURL, voteUpCount: voteUpCount,
            favoriteCount: max(0, count), commentCount: commentCount, voteState: voteState,
            favoriteState: state, createdTimeSeconds: createdTimeSeconds,
            updatedTimeSeconds: updatedTimeSeconds, ipLocation: ipLocation,
            invitationPreface: invitationPreface, endorsements: endorsements
        )
    }
}

struct QAInlineStyle: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let strong = Self(rawValue: 1 << 0)
    static let emphasis = Self(rawValue: 1 << 1)
    static let strikethrough = Self(rawValue: 1 << 2)
    static let code = Self(rawValue: 1 << 3)
}

struct QAInlineRun: Identifiable, Hashable, Sendable {
    let id: UUID
    let text: String
    let style: QAInlineStyle
    let link: QALinkDestination?

    init(id: UUID = UUID(), text: String, style: QAInlineStyle = [], link: QALinkDestination? = nil) {
        self.id = id
        self.text = text
        self.style = style
        self.link = link
    }
}

enum QALinkDestination: Hashable, Sendable {
    case answer(Int64)
    case article(Int64)
    case question(Int64)
    case person(urlToken: String)
    case external(URL)
}

enum QAListKind: Hashable, Sendable {
    case ordered
    case unordered
}

struct QAListItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let runs: [QAInlineRun]
    init(id: UUID = UUID(), runs: [QAInlineRun]) { self.id = id; self.runs = runs }
}

struct QAImageDTO: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let caption: String?
    let altText: String?

    init(id: UUID = UUID(), url: URL, caption: String? = nil, altText: String? = nil) {
        self.id = id
        self.url = url
        self.caption = caption
        self.altText = altText
    }
}

enum QABodyBlock: Identifiable, Hashable, Sendable {
    case paragraph(UUID, [QAInlineRun])
    case heading(UUID, level: Int, runs: [QAInlineRun])
    case quote(UUID, [QAInlineRun])
    case list(UUID, kind: QAListKind, items: [QAListItem])
    case code(UUID, language: String?, text: String)
    case formula(UUID, latex: String)
    case image(QAImageDTO)
    case segment(UUID, segmentID: String, runs: [QAInlineRun])
    case video(UUID, QAAttachmentVideoDTO)
    case divider(UUID)

    var id: UUID {
        switch self {
        case let .paragraph(id, _), let .heading(id, _, _), let .quote(id, _), let .list(id, _, _),
             let .code(id, _, _), let .formula(id, _), let .segment(id, _, _), let .video(id, _),
             let .divider(id): return id
        case let .image(image): return image.id
        }
    }
}

enum QANavigationIntent: Hashable {
    case person(PersonRoutePayload)
    case question(QuestionRouteDTO)
    case answer(AnswerRouteDTO)
    case writeAnswer(WriteAnswerRouteDTO)
    case comments(CommentThreadRouteDTO)
    case images(urls: [URL], initialIndex: Int)
    case link(QALinkDestination)
    case endorsement(URL)
    case segmentComments(CommentThreadRouteDTO)
    case videoPage(URL)
    case share(URL)
}

enum QAInitialLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum QANextPageState: Equatable {
    case idle
    case loading
    case failed(String)
}

struct QAUserMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
}
