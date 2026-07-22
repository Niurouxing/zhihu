import Foundation
import UIKit

enum FeedProjectionPolicy: Equatable {
    case hot
    case search
}

enum FeedResponseMapper {
    static func page(from data: Data, policy: FeedProjectionPolicy) throws -> FeedPageDTO {
        let envelope: FeedAPIEnvelope
        do {
            envelope = try JSONDecoder.zhihuFeed.decode(FeedAPIEnvelope.self, from: data)
        } catch {
            throw ZhihuAPIError.malformedPayload
        }

        var seen: Set<FeedItemID> = []
        let items = envelope.data
            .flatMap(\.flattenedEntries)
            .compactMap { item(from: $0, policy: policy) }
            .filter { seen.insert($0.id).inserted }
        let nextURL: URL?
        do {
            nextURL = try ZhihuAPIURLPolicy.validatedPagingURL(
                envelope.paging?.next.flatMap(URL.init(string:))
            )
        } catch {
            throw ZhihuAPIError.malformedPayload
        }
        return FeedPageDTO(
            items: items,
            nextURL: nextURL,
            isEnd: envelope.paging?.isEnd ?? true
        )
    }

    static func suggestions(from data: Data) throws -> [SearchSuggestionDTO] {
        do {
            let response = try JSONDecoder.zhihuFeed.decode(HotSearchResponse.self, from: data)
            return Array(
                response.hotSearchQueries
                    .compactMap { suggestion in
                        guard let query = suggestion.query.trimmedNonEmpty else { return nil }
                        return SearchSuggestionDTO(
                            query: plainText(query),
                            popularityText: suggestion.hotShow?.trimmedNonEmpty,
                            label: suggestion.label?.trimmedNonEmpty
                        )
                    }
                    .prefix(15)
            )
        } catch {
            throw ZhihuAPIError.malformedPayload
        }
    }

    private static func item(from entry: FeedAPIEntry, policy: FeedProjectionPolicy) -> FeedItemDTO? {
        guard let target = entry.displayTarget,
              let kind = FeedItemKind(rawValue: target.type)
        else { return nil }

        let title: String
        let summary: String?
        let details: String
        let route: FeedItemRoute
        guard let contentID = target.id?.value,
              let numericID = Int64(contentID)
        else { return nil }

        switch kind {
        case .answer:
            guard let questionIDValue = target.question?.id?.value,
                  let questionID = Int64(questionIDValue),
                  let questionTitle = (target.question?.title ?? target.question?.name ?? target.title)?.trimmedNonEmpty
            else { return nil }
            title = plainText(questionTitle)
            summary = plainTextOptional(target.excerpt)
            details = metricText(
                kind: "回答",
                first: target.voteupCount.map { "\($0) 赞同" },
                second: target.commentCount.map { "\($0) 评论" },
                source: entry.sourceLabel
            )
            route = .answer(answerID: numericID, questionID: questionID, questionTitle: title)
        case .article:
            guard let articleTitle = target.title?.trimmedNonEmpty else { return nil }
            title = plainText(articleTitle)
            summary = plainTextOptional(target.excerpt)
            details = metricText(
                kind: "文章",
                first: target.voteupCount.map { "\($0) 赞" },
                second: target.commentCount.map { "\($0) 评论" },
                source: entry.sourceLabel
            )
            route = .article(articleID: numericID, title: title)
        case .question:
            guard let questionTitle = (target.title ?? target.name)?.trimmedNonEmpty else { return nil }
            title = plainText(questionTitle)
            summary = plainTextOptional(target.excerpt ?? target.detail)
            details = metricText(
                kind: "问题",
                first: target.followerCount.map { "\($0) 关注" },
                second: target.answerCount.map { "\($0) 回答" },
                source: entry.sourceLabel
            )
            route = .question(questionID: numericID, title: title)
        case .pin:
            title = target.author?.name.trimmedNonEmpty.map { "\(plainText($0))的想法" } ?? "想法"
            summary = plainTextOptional(target.excerptTitle ?? target.excerpt)
            details = metricText(
                kind: "想法",
                first: target.likeCount.map { "\($0) 赞" },
                second: target.commentCount.map { "\($0) 评论" },
                source: entry.sourceLabel
            )
            route = .pin(pinID: numericID)
        case .video:
            guard let videoTitle = target.title?.trimmedNonEmpty else { return nil }
            title = plainText(videoTitle)
            summary = plainTextOptional(target.excerpt ?? target.description?.text)
            details = metricText(
                kind: "视频",
                first: (target.voteCount ?? target.voteupCount).map { "\($0) 赞" },
                second: target.commentCount.map { "\($0) 评论" },
                source: entry.sourceLabel
            )
            route = .video(videoID: numericID)
        }

        return FeedItemDTO(
            id: FeedItemID(kind: kind, contentID: contentID),
            kind: kind,
            title: title,
            summary: summary,
            details: details,
            sourceLabel: entry.sourceLabel.map(plainText),
            author: policy == .hot ? nil : target.author?.dto,
            thumbnailURL: policy == .hot ? nil : target.thumbnailURL,
            route: route
        )
    }

    private static func metricText(kind: String, first: String?, second: String?, source: String?) -> String {
        ([kind] + [first, second, source].compactMap { $0?.trimmedNonEmpty })
            .joined(separator: " · ")
    }

    private static func plainTextOptional(_ html: String?) -> String? {
        html?.trimmedNonEmpty.map(plainText)?.trimmedNonEmpty
    }

    private static func plainText(_ html: String) -> String {
        guard html.contains("<"),
              let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                  ],
                  documentAttributes: nil
              )
        else { return html.trimmingCharacters(in: .whitespacesAndNewlines) }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension JSONDecoder {
    static var zhihuFeed: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private struct FeedAPIEnvelope: Decodable {
    let data: [FeedAPIEntry]
    let paging: Paging?

    struct Paging: Decodable {
        let isEnd: Bool
        let next: String?
    }
}

private struct FeedAPIEntry: Decodable {
    let type: String?
    let target: FeedTargetPayload?
    let object: FeedTargetPayload?
    let detailText: String?
    let actionText: String?
    let momentDesc: String?
    let list: [FeedAPIEntry]?
    let children: [Child]?

    var displayTarget: FeedTargetPayload? { target ?? object }

    var sourceLabel: String? {
        (detailText ?? actionText ?? momentDesc)?.trimmedNonEmpty
    }

    var flattenedEntries: [FeedAPIEntry] {
        type == "feed_group" ? (list ?? []) : [self]
    }

    struct Child: Decodable {
        let type: String?
        let thumbnail: String?
    }
}

private struct FeedTargetPayload: Decodable {
    let id: JSONIdentifier?
    let type: String
    let url: String?
    let title: String?
    let name: String?
    let excerpt: String?
    let excerptTitle: String?
    let description: FeedDescriptionPayload?
    let detail: String?
    let voteupCount: Int?
    let voteCount: Int?
    let likeCount: Int?
    let commentCount: Int?
    let followerCount: Int?
    let answerCount: Int?
    let thumbnail: String?
    let thumbnailInfo: ThumbnailInfo?
    let author: Author?
    let question: Question?

    var thumbnailURL: URL? {
        (thumbnail ?? thumbnailInfo?.thumbnails.first?.url)
            .flatMap(validHTTPSURL)
    }

    struct ThumbnailInfo: Decodable {
        let thumbnails: [Thumbnail]

        struct Thumbnail: Decodable {
            let url: String?
        }
    }

    struct Question: Decodable {
        let id: JSONIdentifier?
        let title: String?
        let name: String?
    }

    struct Author: Decodable {
        let id: String?
        let urlToken: String?
        let name: String
        let avatarUrl: String?
        let headline: String?

        var dto: FeedAuthorDTO? {
            guard let memberID = id?.trimmedNonEmpty,
                  let displayName = name.trimmedNonEmpty
            else { return nil }
            return FeedAuthorDTO(
                memberID: memberID,
                urlToken: urlToken?.trimmedNonEmpty,
                displayName: displayName,
                avatarURL: avatarUrl.flatMap(validHTTPSURL),
                headline: headline ?? ""
            )
        }
    }
}

private struct FeedDescriptionPayload: Decodable {
    let text: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // /api/v4/search_v3 returns video descriptions as text but uses an object
        // for non-content cards such as hot_timing. See GitHub issue #1.
        text = try? container.decode(String.self)
    }
}

private struct HotSearchResponse: Decodable {
    let hotSearchQueries: [Suggestion]

    struct Suggestion: Decodable {
        let query: String
        let hotShow: String?
        let label: String?
    }
}

private struct JSONIdentifier: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let integer = try? container.decode(Int64.self) {
            value = String(integer)
        } else if let number = try? container.decode(Double.self), number.isFinite {
            value = String(format: "%.0f", number)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported identifier")
            )
        }
    }
}

private func validHTTPSURL(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme?.lowercased() == "https" else { return nil }
    return url
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
