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

struct NativeSpecialRepository {
    var fetchSpecial: (_ specialID: String) async throws -> NativeSpecialDetail

    static func live(client: ZhihuAPIClient) -> NativeSpecialRepository {
        NativeSpecialRepository(fetchSpecial: { specialID in
            guard !specialID.isEmpty, specialID.allSatisfy(\.isNumber) else {
                throw ZhihuAPIError.malformedPayload
            }
            let url = URL(string: "https://www.zhihu.com/api/v4/news_specials")!
                .appendingPathComponent(specialID)
            let data = try await client.data(for: url, authentication: .accountIfAvailable)
            return try decodeSpecial(data)
        })
    }

    static func decodeSpecial(_ data: Data) throws -> NativeSpecialDetail {
        try JSONDecoder().decode(RawSpecialPayload.self, from: data).detail
    }
}

struct NativeColumnRepository {
    var fetchColumn: (_ columnID: String) async throws -> NativeColumnDetail
    var fetchItems: (_ columnID: String, _ next: URL?) async throws -> NativePage<NativeLibraryItem>

    static func live(client: ZhihuAPIClient) -> NativeColumnRepository {
        NativeColumnRepository(
            fetchColumn: { columnID in
                guard NativeColumnIDPolicy.isValid(columnID) else {
                    throw ZhihuAPIError.malformedPayload
                }
                let url = URL(string: "https://www.zhihu.com/api/v4/columns")!
                    .appendingPathComponent(columnID)
                return try decodeColumn(await client.data(
                    for: url,
                    authentication: .accountIfAvailable
                ))
            },
            fetchItems: { columnID, next in
                guard NativeColumnIDPolicy.isValid(columnID) else {
                    throw ZhihuAPIError.malformedPayload
                }
                let initial = columnItemsURL(columnID)
                let url = try ZhihuAPIURLPolicy.validatedPagingURL(next) ?? initial
                return try decodeItems(await client.data(
                    for: url,
                    authentication: .accountIfAvailable
                ))
            }
        )
    }

    static func decodeColumn(_ data: Data) throws -> NativeColumnDetail {
        try JSONDecoder().decode(RawColumnDetail.self, from: data).detail
    }

    static func decodeItems(_ data: Data) throws -> NativePage<NativeLibraryItem> {
        let payload = try JSONDecoder().decode(ColumnItemsPayload.self, from: data)
        return try NativePage(
            items: payload.data.compactMap(\.value).compactMap(\.libraryItem),
            paging: NativePaging(
                next: ZhihuAPIURLPolicy.validatedPagingURL(payload.paging?.nextURL),
                isEnd: payload.paging?.isEnd ?? true
            )
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

private func columnItemsURL(_ columnID: String) -> URL {
    var components = URLComponents(
        url: URL(string: "https://www.zhihu.com/api/v4/columns")!
            .appendingPathComponent(columnID)
            .appendingPathComponent("items"),
        resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
        URLQueryItem(name: "limit", value: "10"),
        URLQueryItem(name: "offset", value: "0"),
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

private struct ColumnItemsPayload: Decodable {
    let data: [NativeLossyDecoded<RawCollectionContent>]
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

private struct RawColumnDetail: Decodable {
    let id: String
    let title: String
    let description: String?
    let imageURLString: String?
    let itemCount: Int?
    let articleCount: Int?
    let followersCount: Int?
    let voteupCount: Int?
    let author: RawColumnAuthor?

    private enum CodingKeys: String, CodingKey {
        case id, title, description, author
        case imageURLString = "image_url"
        case itemCount = "items_count"
        case articleCount = "articles_count"
        case followersCount = "followers"
        case voteupCount = "voteup_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleString(forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description)
        imageURLString = try container.decodeIfPresent(String.self, forKey: .imageURLString)
        itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount)
        articleCount = try container.decodeIfPresent(Int.self, forKey: .articleCount)
        followersCount = try container.decodeIfPresent(Int.self, forKey: .followersCount)
        voteupCount = try container.decodeIfPresent(Int.self, forKey: .voteupCount)
        author = try container.decodeIfPresent(RawColumnAuthor.self, forKey: .author)
    }

    var detail: NativeColumnDetail {
        NativeColumnDetail(
            id: id,
            title: title,
            description: description ?? "",
            imageURL: imageURLString.flatMap(URL.init(string:)),
            itemCount: itemCount ?? articleCount ?? 0,
            followersCount: followersCount ?? 0,
            voteupCount: voteupCount ?? 0,
            author: author?.value
        )
    }
}

private struct RawColumnAuthor: Decodable {
    let name: String?
    let urlToken: String?
    let avatarURLString: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case urlToken = "url_token"
        case avatarURLString = "avatar_url"
    }

    var value: NativeColumnAuthor {
        NativeColumnAuthor(
            name: name ?? "",
            urlToken: urlToken ?? "",
            avatarURL: avatarURLString.flatMap(URL.init(string:))
        )
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

private struct RawSpecialPayload: Decodable {
    let id: String
    let title: String
    let introduction: String?
    let banner: String?
    let contentCount: Int?
    let viewCount: Int?
    let followersCount: Int?
    let updated: Int64?
    let selectedContents: [NativeLossyDecoded<RawSpecialGroup>]?

    private enum CodingKeys: String, CodingKey {
        case id, title, introduction, banner, updated
        case contentCount = "content_count"
        case viewCount = "view_count"
        case followersCount = "followers_count"
        case selectedContents = "selected_contents"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleString(forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        introduction = try container.decodeIfPresent(String.self, forKey: .introduction)
        banner = try container.decodeIfPresent(String.self, forKey: .banner)
        contentCount = try container.decodeIfPresent(Int.self, forKey: .contentCount)
        viewCount = try container.decodeIfPresent(Int.self, forKey: .viewCount)
        followersCount = try container.decodeIfPresent(Int.self, forKey: .followersCount)
        updated = try container.decodeIfPresent(Int64.self, forKey: .updated)
        selectedContents = try container.decodeIfPresent(
            [NativeLossyDecoded<RawSpecialGroup>].self,
            forKey: .selectedContents
        )
    }

    var detail: NativeSpecialDetail {
        NativeSpecialDetail(
            id: id,
            title: title,
            introduction: introduction ?? "",
            bannerURL: banner.flatMap(specialTrustedImageURL),
            contentCount: contentCount ?? 0,
            viewCount: viewCount ?? 0,
            followersCount: followersCount ?? 0,
            updatedTime: updated ?? 0,
            groups: (selectedContents ?? []).compactMap(\.value).map(\.group)
        )
    }
}

private struct RawSpecialGroup: Decodable {
    let id: String
    let title: String?
    let content: [RawSpecialSection]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleString(forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        content = try container.decodeIfPresent([RawSpecialSection].self, forKey: .content)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, content
    }

    var group: NativeSpecialGroup {
        NativeSpecialGroup(
            id: id,
            title: title ?? "",
            sections: (content ?? []).map(\.section)
        )
    }
}

private struct RawSpecialSection: Decodable {
    let id: String
    let title: String?
    let content: [NativeLossyDecoded<RawSpecialItem>]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleString(forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        content = try container.decodeIfPresent([NativeLossyDecoded<RawSpecialItem>].self, forKey: .content)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, content
    }

    var section: NativeSpecialSection {
        NativeSpecialSection(
            id: id,
            title: title ?? "",
            items: (content ?? []).compactMap(\.value).map(\.item)
        )
    }
}

private struct RawSpecialItem: Decodable {
    let id: String
    let type: String
    let title: String?
    let excerpt: String?
    let thumbnail: String?
    let imagePath: String?
    let videoToken: String?
    let author: RawSpecialAuthor?
    let tags: [RawSpecialTag]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleString(forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt)
        thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnail)
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
        videoToken = try? container.decodeFlexibleString(forKey: .videoToken)
        author = try container.decodeIfPresent(RawSpecialAuthor.self, forKey: .author)
        tags = try container.decodeIfPresent([RawSpecialTag].self, forKey: .tags)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, excerpt, thumbnail, author, tags
        case imagePath = "image_path"
        case videoToken = "video_token"
    }

    var item: NativeSpecialItem {
        let displayTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = displayTitle.flatMap { $0.isEmpty ? nil : $0 } ?? type
        let imageURL = [imagePath, thumbnail]
            .compactMap { $0 }
            .compactMap(specialTrustedImageURL)
            .first
        return NativeSpecialItem(
            id: "\(type):\(id)",
            contentType: type,
            title: resolvedTitle,
            excerpt: excerpt ?? "",
            authorName: author?.name,
            imageURL: imageURL,
            tags: (tags ?? []).map(\.tag),
            route: route(title: resolvedTitle, imageURL: imageURL)
        )
    }

    private func route(title: String, imageURL: URL?) -> FeedItemRoute? {
        guard let numericID = Int64(id) else { return nil }
        switch type {
        case "answer":
            return .answer(answerID: numericID, questionID: nil, questionTitle: title)
        case "article":
            return .article(articleID: numericID, title: title)
        case "question":
            return .question(questionID: numericID, title: title)
        case "pin":
            return .pin(pinID: numericID)
        case "zvideo":
            return .video(.init(
                contentID: numericID,
                videoID: videoToken.flatMap(Int64.init),
                contentType: .zvideo,
                title: title,
                thumbnailURL: imageURL,
                webURL: URL(string: "https://www.zhihu.com/zvideo/\(numericID)")
            ))
        default:
            return nil
        }
    }
}

private struct RawSpecialAuthor: Decodable {
    let name: String?
}

private struct RawSpecialTag: Decodable {
    let name: String?
    let value: Int64?

    var tag: NativeSpecialTag {
        NativeSpecialTag(name: name ?? "", value: value ?? 0)
    }
}

private func specialTrustedImageURL(_ rawValue: String) -> URL? {
    let normalized = rawValue.hasPrefix("//") ? "https:\(rawValue)" : rawValue
    guard let url = URL(string: normalized),
          url.scheme?.lowercased() == "https",
          url.user == nil,
          url.password == nil,
          let host = url.host?.lowercased(),
          host == "zhimg.com" || host.hasSuffix(".zhimg.com")
    else { return nil }
    return url
}
