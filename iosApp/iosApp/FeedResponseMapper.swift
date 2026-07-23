import Foundation
import UIKit

#if DEBUG
import os
#endif

enum FeedProjectionPolicy: Equatable {
    case hot
    case search
}

enum FeedResponseEndpointCategory: String {
    case unspecified = "unspecified"
    case followRecommendations = "follow.recommendations"
    case followMoments = "follow.moments"
}

enum FeedResponseMapper {
    static func page(
        from data: Data,
        policy: FeedProjectionPolicy,
        endpointCategory: FeedResponseEndpointCategory = .unspecified
    ) throws -> FeedPageDTO {
        let envelope: FeedAPIEnvelope
        do {
            envelope = try JSONDecoder.zhihuFeed.decode(FeedAPIEnvelope.self, from: data)
        } catch {
            #if DEBUG
            if let decodingError = error as? DecodingError {
                logDecodingFailure(decodingError, endpointCategory: endpointCategory)
            }
            #endif
            throw ZhihuAPIError.malformedPayload
        }

        var seen: Set<FeedItemID> = []
        let items = envelope.data
            .flatMap(\.flattenedEntries)
            .compactMap { item(from: $0, policy: policy) }
            .filter { seen.insert($0.id).inserted }
        let rawNextURL = envelope.paging?.next
        let parsedNextURL = rawNextURL.flatMap(URL.init(string:))
        let nextURL: URL?
        do {
            nextURL = try ZhihuAPIURLPolicy.validatedPagingURL(parsedNextURL)
        } catch {
            #if DEBUG
            logPagingValidationFailure(
                parsedURL: parsedNextURL,
                endpointCategory: endpointCategory,
                error: error
            )
            #endif
            throw ZhihuAPIError.malformedPayload
        }
        return FeedPageDTO(
            items: items,
            nextURL: nextURL,
            isEnd: envelope.paging?.isEnd ?? true
        )
    }

    #if DEBUG
    private static let diagnosticsLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.github.zly2006.zhplus.ios",
        category: "FeedDecodeDiagnostics"
    )

    private static func logDecodingFailure(
        _ error: DecodingError,
        endpointCategory: FeedResponseEndpointCategory
    ) {
        let details = decodingErrorDetails(error)
        diagnosticsLogger.debug(
            "FeedDecodeDiagnostics decode_failure endpoint=\(endpointCategory.rawValue, privacy: .public) case=\(details.caseName, privacy: .public) codingPath=\(details.codingPath, privacy: .public) debugDescription=\(details.debugDescription, privacy: .public) expectedType=\(details.expectedType, privacy: .public) underlyingType=\(details.underlyingType, privacy: .public)"
        )
    }

    private static func logPagingValidationFailure(
        parsedURL: URL?,
        endpointCategory: FeedResponseEndpointCategory,
        error: Error
    ) {
        let host = parsedURL?.host ?? "none"
        let path = parsedURL?.path.isEmpty == false ? parsedURL?.path ?? "none" : "none"
        let isRelative = parsedURL.map { $0.scheme == nil } ?? false
        let errorType = String(reflecting: type(of: error))
        diagnosticsLogger.debug(
            "FeedDecodeDiagnostics paging_validation_failure endpoint=\(endpointCategory.rawValue, privacy: .public) host=\(host, privacy: .public) path=\(path, privacy: .public) isRelative=\(isRelative, privacy: .public) errorType=\(errorType, privacy: .public)"
        )
    }

    private static func decodingErrorDetails(
        _ error: DecodingError
    ) -> (
        caseName: String,
        codingPath: String,
        debugDescription: String,
        expectedType: String,
        underlyingType: String
    ) {
        let caseName: String
        let context: DecodingError.Context
        let expectedType: String
        switch error {
        case let .typeMismatch(type, errorContext):
            caseName = "typeMismatch"
            context = errorContext
            expectedType = String(reflecting: type)
        case let .valueNotFound(type, errorContext):
            caseName = "valueNotFound"
            context = errorContext
            expectedType = String(reflecting: type)
        case let .keyNotFound(key, errorContext):
            caseName = "keyNotFound"
            context = errorContext
            expectedType = key.stringValue
        case let .dataCorrupted(errorContext):
            caseName = "dataCorrupted"
            context = errorContext
            expectedType = "none"
        @unknown default:
            caseName = "unknown"
            context = DecodingError.Context(
                codingPath: [],
                debugDescription: "Unknown DecodingError case"
            )
            expectedType = "none"
        }
        let codingPath = context.codingPath
            .map { key in key.intValue.map { "[\($0)]" } ?? key.stringValue }
            .joined(separator: ".")
        let underlyingType = context.underlyingError
            .map { String(reflecting: type(of: $0)) } ?? "none"
        return (
            caseName,
            codingPath.isEmpty ? "root" : codingPath,
            context.debugDescription,
            expectedType,
            underlyingType
        )
    }
    #endif

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
            title = target.decodedAuthor?.name.trimmedNonEmpty.map { "\(plainText($0))的想法" } ?? "想法"
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
            author: policy == .hot ? nil : target.decodedAuthor?.dto,
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
    let author: AuthorField?
    let question: Question?

    var decodedAuthor: Author? { author?.value }

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

    struct AuthorField: Decodable {
        let value: Author?

        init(from decoder: Decoder) throws {
            do {
                _ = try decoder.container(keyedBy: ShapeKey.self)
            } catch DecodingError.typeMismatch {
                value = nil
                return
            }
            value = try Author(from: decoder)
        }

        private struct ShapeKey: CodingKey {
            let stringValue: String
            let intValue: Int?

            init?(stringValue: String) {
                self.stringValue = stringValue
                intValue = nil
            }

            init?(intValue: Int) {
                stringValue = String(intValue)
                self.intValue = intValue
            }
        }
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
