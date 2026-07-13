import Foundation

struct NativeLibraryRepository {
    var fetchCollections: (_ userToken: String, _ next: URL?) async throws -> NativePage<NativeLibraryCollection>
    var fetchCollection: (_ collectionID: String) async throws -> NativeLibraryCollection
    var fetchCollectionItems: (_ collectionID: String, _ next: URL?) async throws -> NativePage<NativeLibraryItem>
    var fetchHistory: (_ next: URL?) async throws -> NativePage<NativeHistoryItem>
    var clearHistory: () async throws -> Void

    static func live(client: ZhihuAPIClient) -> NativeLibraryRepository {
        let decoder = JSONDecoder()
        return NativeLibraryRepository(
            fetchCollections: { userToken, next in
                let initial = URL(string: "https://www.zhihu.com/api/v4/people")!
                    .appendingPathComponent(userToken)
                    .appendingPathComponent("collections")
                let url = try ZhihuAPIURLPolicy.validatedPagingURL(next) ?? collectionURLWithInclude(initial)
                let payload = try decoder.decode(
                    CollectionListPayload.self,
                    from: await client.data(for: url, authentication: .accountRequired)
                )
                return try NativePage(
                    items: payload.data,
                    paging: NativePaging(next: ZhihuAPIURLPolicy.validatedPagingURL(payload.paging?.nextURL), isEnd: payload.paging?.isEnd ?? true)
                )
            },
            fetchCollection: { collectionID in
                let url = URL(string: "https://www.zhihu.com/api/v4/collections")!
                    .appendingPathComponent(collectionID)
                let payload = try decoder.decode(
                    CollectionDetailPayload.self,
                    from: await client.data(for: url, authentication: .accountRequired)
                )
                return payload.collection
            },
            fetchCollectionItems: { collectionID, next in
                let initial = URL(string: "https://www.zhihu.com/api/v4/collections")!
                    .appendingPathComponent(collectionID)
                    .appendingPathComponent("items")
                let url = try ZhihuAPIURLPolicy.validatedPagingURL(next) ?? collectionURLWithInclude(initial)
                let payload = try decoder.decode(
                    CollectionItemsPayload.self,
                    from: await client.data(for: url, authentication: .accountRequired)
                )
                return try NativePage(
                    items: payload.data.compactMap(\.value).compactMap(\.libraryItem),
                    paging: NativePaging(next: ZhihuAPIURLPolicy.validatedPagingURL(payload.paging?.nextURL), isEnd: payload.paging?.isEnd ?? true)
                )
            },
            fetchHistory: { next in
                let url = try ZhihuAPIURLPolicy.validatedPagingURL(next)
                    ?? URL(string: "https://api.zhihu.com/unify-consumption/read_history?offset=0&limit=10")!
                let payload = try decoder.decode(
                    HistoryPayload.self,
                    from: await client.data(for: url, authentication: .accountRequired)
                )
                return try NativePage(
                    items: payload.data.compactMap(\.value).map(\.historyItem),
                    paging: NativePaging(next: ZhihuAPIURLPolicy.validatedPagingURL(payload.paging?.nextURL), isEnd: payload.paging?.isEnd ?? true)
                )
            },
            clearHistory: {
                let url = URL(string: "https://api.zhihu.com/read_history/batch_del")!
                let body = try JSONSerialization.data(withJSONObject: ["pairs": [], "clear": true])
                _ = try await client.data(
                    for: url,
                    method: "POST",
                    body: body,
                    additionalHeaders: ["Content-Type": "application/json"],
                    authentication: .accountRequired
                )
            }
        )
    }
}

private func collectionURLWithInclude(_ url: URL) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = [
        URLQueryItem(name: "include", value: "data[*].content,excerpt,headline,target.author.badge_v2")
    ]
    return components.url!
}

private struct PagingPayload: Decodable {
    let isEnd: Bool
    let next: String?

    var nextURL: URL? { next.flatMap(URL.init(string:)) }

    private enum CodingKeys: String, CodingKey {
        case isEnd = "is_end"
        case next
    }
}

private struct CollectionListPayload: Decodable {
    let data: [NativeLibraryCollection]
    let paging: PagingPayload?
}

private struct CollectionDetailPayload: Decodable {
    let collection: NativeLibraryCollection
}

private struct CollectionItemsPayload: Decodable {
    let data: [NativeLossyDecoded<RawCollectionItem>]
    let paging: PagingPayload?
}

private struct RawCollectionItem: Decodable {
    let created: String?
    let content: RawCollectionContent

    var libraryItem: NativeLibraryItem? { content.libraryItem }
}

private struct RawCollectionContent: Decodable {
    let type: String
    let id: String
    let url: String?
    let title: String?
    let name: String?
    let excerpt: String?
    let excerptTitle: String?
    let author: RawPerson?
    let question: RawQuestion?
    let voteupCount: Int?
    let likeCount: Int?
    let commentCount: Int?
    let followerCount: Int?
    let answerCount: Int?

    private enum CodingKeys: String, CodingKey {
        case type, id, url, title, name, excerpt, author, question
        case excerptTitle = "excerpt_title"
        case voteupCount = "voteup_count"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case followerCount = "follower_count"
        case answerCount = "answer_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decodeFlexibleString(forKey: .id)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt)
        excerptTitle = try container.decodeIfPresent(String.self, forKey: .excerptTitle)
        author = try container.decodeIfPresent(RawPerson.self, forKey: .author)
        question = try container.decodeIfPresent(RawQuestion.self, forKey: .question)
        voteupCount = try container.decodeIfPresent(Int.self, forKey: .voteupCount)
        likeCount = try container.decodeIfPresent(Int.self, forKey: .likeCount)
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount)
        followerCount = try container.decodeIfPresent(Int.self, forKey: .followerCount)
        answerCount = try container.decodeIfPresent(Int.self, forKey: .answerCount)
    }

    var libraryItem: NativeLibraryItem? {
        guard let numericID = Int64(id) else { return nil }
        let destination: NativeContentDestination?
        let resolvedTitle: String
        let detail: String
        switch type {
        case "answer":
            destination = .article(id: numericID, kind: .answer)
            resolvedTitle = question?.displayTitle ?? title ?? "回答"
            detail = "回答 · \(voteupCount ?? 0) 赞同 · \(commentCount ?? 0) 评论"
        case "article":
            destination = .article(id: numericID, kind: .article)
            resolvedTitle = title ?? "文章"
            detail = "文章 · \(voteupCount ?? 0) 赞同 · \(commentCount ?? 0) 评论"
        case "question":
            destination = .question(id: numericID)
            resolvedTitle = title ?? name ?? "问题"
            detail = "问题 · \(followerCount ?? 0) 关注 · \(answerCount ?? 0) 回答"
        case "pin":
            destination = .pin(id: numericID)
            resolvedTitle = author.map { "\($0.name)的想法" } ?? "想法"
            detail = "想法 · \(likeCount ?? 0) 赞 · \(commentCount ?? 0) 评论"
        default:
            destination = NativeContentDestinationResolver.resolve(url)
            resolvedTitle = title ?? name ?? type
            detail = type
        }
        return NativeLibraryItem(
            id: "\(type):\(id)",
            title: resolvedTitle,
            summary: excerpt ?? excerptTitle ?? "",
            detail: detail,
            authorName: author?.name,
            avatarURL: author?.avatarURL,
            destination: destination
        )
    }
}

private struct RawQuestion: Decodable {
    let title: String?
    let name: String?
    var displayTitle: String { title ?? name ?? "回答" }
}

private struct RawPerson: Decodable {
    let name: String
    let avatarURLString: String?
    var avatarURL: URL? { avatarURLString.flatMap(URL.init(string:)) }

    private enum CodingKeys: String, CodingKey {
        case name
        case avatarURLString = "avatar_url"
    }
}

private struct HistoryPayload: Decodable {
    let data: [NativeLossyDecoded<RawHistoryItem>]
    let paging: PagingPayload?
}

private struct RawHistoryItem: Decodable {
    let cardType: String
    let data: RawHistoryData

    private enum CodingKeys: String, CodingKey {
        case cardType = "card_type"
        case data
    }

    var historyItem: NativeHistoryItem {
        let id = data.extra.contentToken.isEmpty
            ? "\(data.extra.readTime):\(cardType):\(data.header.title)"
            : "\(data.extra.contentType):\(data.extra.contentToken)"
        return NativeHistoryItem(
            id: id,
            title: data.header.title,
            summary: data.content?.summary ?? "",
            detail: data.matrix?.first?.data.text ?? data.extra.contentType,
            authorName: data.content?.authorName,
            coverURL: data.content?.coverImage.flatMap(URL.init(string:)),
            readTime: data.extra.readTime,
            destination: NativeContentDestinationResolver.resolve(data.action.url)
        )
    }
}

private struct RawHistoryData: Decodable {
    let header: RawHistoryHeader
    let content: RawHistoryContent?
    let action: RawHistoryAction
    let extra: RawHistoryExtra
    let matrix: [RawHistoryMatrix]?
}

private struct RawHistoryHeader: Decodable { let title: String }
private struct RawHistoryAction: Decodable { let url: String }
private struct RawHistoryMatrix: Decodable { let data: RawHistoryMatrixData }
private struct RawHistoryMatrixData: Decodable { let text: String }

private struct RawHistoryContent: Decodable {
    let authorName: String?
    let summary: String?
    let coverImage: String?

    private enum CodingKeys: String, CodingKey {
        case authorName = "author_name"
        case summary
        case coverImage = "cover_image"
    }
}

private struct RawHistoryExtra: Decodable {
    let contentToken: String
    let contentType: String
    let readTime: Int64

    private enum CodingKeys: String, CodingKey {
        case contentToken = "content_token"
        case contentType = "content_type"
        case readTime = "read_time"
    }
}
