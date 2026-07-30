import Foundation
import UIKit

struct PersonIdentity: Hashable {
    let memberID: String?
    let urlToken: String?

    init(route: PersonRoutePayload, profile: PersonProfile? = nil) {
        memberID = profile?.memberID.nonBlank ?? route.memberID
        urlToken = profile?.urlToken?.nonBlank ?? route.urlToken
    }

    var preferredIdentifier: String? { urlToken?.nonBlank ?? memberID?.nonBlank }
}

protocol PersonRepository {
    func fetchProfile(identity: PersonIdentity, provisionalDisplayName: String) async throws -> PersonProfile
    func fetchPage(
        key: PersonPageKey,
        identity: PersonIdentity,
        sort: PersonContentSort?,
        nextURL: URL?
    ) async throws -> PersonPageResult
    func setFollowing(_ target: Bool, profile: PersonProfile) async throws -> PersonFollowResult
    func setBlocking(_ target: Bool, profile: PersonProfile) async throws
    func recordReadHistory(profileID: String) async
}

extension PersonRepository {
    func recordReadHistory(profileID: String) async {}
}

actor URLSessionPersonRepository: PersonRepository {
    private let client: ZhihuAPIClient

    init(
        accountStore: AccountJSONStore,
        session: URLSession? = nil,
        signer: ZhihuRequestSigning = ZhihuRequestSigner()
    ) {
        client = ZhihuAPIClient(accountStore: accountStore, session: session, signer: signer)
    }

    func fetchProfile(identity: PersonIdentity, provisionalDisplayName: String) async throws -> PersonProfile {
        guard let identifier = identity.preferredIdentifier else {
            throw PersonRepositoryError.invalidRoute
        }
        let url = try endpoint(
            base: "https://api.zhihu.com/people/\(pathSegment(identifier))",
            queryItems: [
                URLQueryItem(
                    name: "include",
                    value: "allow_message,is_followed,is_following,is_org,is_blocking,badge_v2,answer_count,follower_count,following_count,articles_count,question_count,pins_count"
                ),
            ]
        )
        let data = try await client.data(for: url, authentication: .accountRequired)
        let response = try JSONDecoder.person.decode(ProfileResponse.self, from: data)
        return response.profile(provisionalDisplayName: provisionalDisplayName)
    }

    func recordReadHistory(profileID: String) async {
        await client.recordReadHistory(contentToken: profileID, contentType: "profile")
    }

    func fetchPage(
        key: PersonPageKey,
        identity: PersonIdentity,
        sort: PersonContentSort?,
        nextURL: URL?
    ) async throws -> PersonPageResult {
        let url: URL
        if let nextURL {
            url = try validatedPageURL(upgradingToHTTPS(nextURL))
        } else {
            url = try initialPageURL(key: key, identity: identity, sort: sort)
        }
        let data = try await client.data(for: url, authentication: .accountRequired)
        let envelope = try JSONDecoder.person.decode(PageEnvelope.self, from: data)
        let items = try PersonPageMapper.map(data: data, key: key)
        let acceptedNextURL = try envelope.paging?.next.flatMap(URL.init(string:)).map {
            try validatedPageURL(upgradingToHTTPS($0))
        }
        return PersonPageResult(
            items: items,
            nextURL: acceptedNextURL,
            isEnd: envelope.paging?.isEnd ?? true
        )
    }

    func setFollowing(_ target: Bool, profile: PersonProfile) async throws -> PersonFollowResult {
        guard let token = profile.urlToken?.nonBlank else {
            throw PersonRepositoryError.missingMutationToken
        }
        let url = try requiredURL("https://www.zhihu.com/api/v4/members/\(pathSegment(token))/followers")
        let data = try await client.data(
            for: url,
            method: target ? "POST" : "DELETE",
            authentication: .accountRequired
        )
        let response = try? JSONDecoder.person.decode(FollowResponse.self, from: data)
        let fallbackCount = profile.followerCount + (target ? 1 : -1)
        return PersonFollowResult(
            isFollowing: target,
            followerCount: response?.followerCount ?? max(0, fallbackCount)
        )
    }

    func setBlocking(_ target: Bool, profile: PersonProfile) async throws {
        guard let token = profile.urlToken?.nonBlank else {
            throw PersonRepositoryError.missingMutationToken
        }
        let url = try requiredURL("https://www.zhihu.com/api/v4/members/\(pathSegment(token))/actions/block")
        _ = try await client.data(
            for: url,
            method: target ? "POST" : "DELETE",
            authentication: .accountRequired
        )
    }

    private func initialPageURL(
        key: PersonPageKey,
        identity: PersonIdentity,
        sort: PersonContentSort?
    ) throws -> URL {
        guard let identifier = identity.preferredIdentifier else {
            throw PersonRepositoryError.invalidRoute
        }
        let member = pathSegment(identifier)
        let specification: (String, String?)
        switch key {
        case .main(.answers):
            specification = (
                "https://www.zhihu.com/api/v4/members/\(member)/answers",
                "data[*].is_normal,admin_closed_comment,reward_info,is_collapsed,annotation_action,annotation_detail,collapse_reason,collapsed_by,suggest_edit,comment_count,thanks_count,can_comment,content,editable_content,attachment,voteup_count,reshipment_settings,comment_permission,created_time,updated_time,review_info,excerpt,paid_info,reaction_instruction,is_labeled,label_info,relationship.is_authorized,voting,is_author,is_thanked,is_nothelp,author.badge_v2"
            )
        case .main(.articles):
            specification = (
                "https://www.zhihu.com/api/v4/members/\(member)/articles",
                "data[*].comment_count,suggest_edit,is_normal,thumbnail_extra_info,thumbnail,can_comment,comment_permission,admin_closed_comment,content,voteup_count,created,updated,upvoted_followees,voting,review_info,reaction_instruction,is_labeled,label_info,author.badge_v2;data[*].vessay_info;data[*].author.badge[?(type=best_answerer)].topics;"
            )
        case .main(.activities):
            specification = (
                "https://www.zhihu.com/api/v3/moments/\(member)/activities",
                "data[*].content,excerpt,headline,target.author.badge_v2"
            )
        case .main(.collections):
            specification = ("https://www.zhihu.com/api/v4/members/\(member)/favlists", "data[*].updated_time,answer_count,follower_count,creator")
        case .main(.questions):
            specification = ("https://www.zhihu.com/api/v4/members/\(member)/questions", "data[*].created,answer_count,follower_count,author,visit_count,comment_count,detail,relationship,topics,voteup_count")
        case .main(.pins):
            specification = ("https://www.zhihu.com/api/v4/v2/pins/\(member)/moments", "data[*].like_count,comment_count,created,updated,content")
        case .main(.columns):
            specification = ("https://www.zhihu.com/api/v4/members/\(member)/column-contributions", "data[*].articles_count,followers,author")
        case .main(.followers):
            guard let memberID = identity.memberID?.nonBlank else {
                throw PersonRepositoryError.missingCanonicalMemberID
            }
            specification = ("https://api.zhihu.com/people/\(pathSegment(memberID))/followers", Self.peopleInclude)
        case .main(.following):
            specification = ("https://www.zhihu.com/api/v4/members/\(member)/followees", Self.peopleInclude)
        case .main(.subscriptions):
            throw PersonRepositoryError.invalidPage
        case .subscription(.followingColumns):
            specification = ("https://www.zhihu.com/api/v4/members/\(member)/following-columns", "data[*].articles_count,followers,author")
        case .subscription(.followingTopics):
            specification = ("https://www.zhihu.com/api/v4/members/\(member)/following-topic-contributions", nil)
        case .subscription(.followingQuestions):
            specification = ("https://www.zhihu.com/api/v4/members/\(member)/following-questions", nil)
        case .subscription(.followingCollections):
            specification = ("https://www.zhihu.com/api/v4/members/\(member)/following-favlists", "data[*].updated_time,answer_count,follower_count,creator")
        }

        var queryItems: [URLQueryItem] = []
        if case .main(.answers) = key {
            queryItems.append(URLQueryItem(name: "sort_by", value: (sort ?? .voteups).rawValue))
        } else if case .main(.articles) = key {
            queryItems.append(URLQueryItem(name: "sort_by", value: (sort ?? .created).rawValue))
        }
        if let include = specification.1 {
            queryItems.append(URLQueryItem(name: "include", value: include))
        }
        return try endpoint(base: specification.0, queryItems: queryItems)
    }

    private func endpoint(base: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw PersonRepositoryError.invalidURL }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw PersonRepositoryError.invalidURL }
        return url
    }

    private func requiredURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw PersonRepositoryError.invalidURL }
        return url
    }

    private func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .personPathSegment) ?? value
    }

    private func upgradingToHTTPS(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }

    private func validatedPageURL(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "www.zhihu.com" || host == "api.zhihu.com",
              url.path == "/api" || url.path.hasPrefix("/api/") || url.path.hasPrefix("/people/")
        else { throw PersonRepositoryError.malformedPayload }
        return url
    }

    private static let peopleInclude = "data[*].answer_count,articles_count,gender,follower_count,is_followed,is_following,badge_v2,badge[?(type=best_answerer)].topics"
}

enum PersonRepositoryError: LocalizedError {
    case invalidRoute
    case invalidPage
    case invalidURL
    case missingCanonicalMemberID
    case missingMutationToken
    case accountUnavailable
    case invalidResponse
    case httpStatus(Int)
    case malformedPayload

    var errorDescription: String? {
        switch self {
        case .invalidRoute: return "用户地址无效"
        case .invalidPage: return "当前内容类型无法加载"
        case .invalidURL: return "请求地址无效"
        case .missingCanonicalMemberID: return "用户资料尚未加载完成，请重试"
        case .missingMutationToken: return "当前账号标识不支持此操作"
        case .accountUnavailable: return "账号信息读取失败，请重新登录后重试"
        case .invalidResponse: return "服务器返回了无效响应"
        case let .httpStatus(status): return "请求失败（HTTP \(status)）"
        case .malformedPayload: return "内容格式无法识别"
        }
    }
}

private extension CharacterSet {
    static let personPathSegment = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension JSONDecoder {
    static var person: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private struct PageEnvelope: Decodable {
    let paging: Paging?

    struct Paging: Decodable {
        let isEnd: Bool
        let next: String?
    }
}

private struct FollowResponse: Decodable {
    let followerCount: Int?
}

private struct BadgeContainerResponse: Decodable {
    let title: String?
    let icon: String?
    let nightIcon: String?
    let detailBadges: [BadgeResponse]?
    let mergedBadges: [BadgeResponse]?
}

private struct BadgeResponse: Decodable {
    let type: String?
    let detailType: String?
    let title: String?
    let description: String?
    let url: String?
    let icon: String?
    let nightIcon: String?
    let badgeStatus: String?

    func mapped() -> PersonOfficialBadge? {
        guard badgeStatus == nil || badgeStatus == "passed",
              let title = title?.nonBlank
        else { return nil }
        return PersonOfficialBadge(
            title: title,
            description: description?.nonBlank ?? title,
            iconURL: icon.flatMap(validURL),
            nightIconURL: nightIcon.flatMap(validURL),
            destinationURL: url.flatMap(validURL),
            typeRaw: type?.nonBlank,
            detailTypeRaw: detailType?.nonBlank
        )
    }
}

private struct ProfileResponse: Decodable {
    let id: String
    let urlToken: String?
    let name: String?
    let avatarUrl: String?
    let headline: String?
    let badgeV2: BadgeContainerResponse?
    let followerCount: Int?
    let followingCount: Int?
    let answerCount: Int?
    let articlesCount: Int?
    let isFollowing: Bool?
    let isBlocking: Bool?

    func profile(provisionalDisplayName: String) -> PersonProfile {
        let details = (badgeV2?.detailBadges ?? badgeV2?.mergedBadges ?? []).compactMap { $0.mapped() }
        let preferredPrimary = details.first { $0.typeRaw != "identity" && $0.iconURL != nil }
            ?? details.first { $0.iconURL != nil }
        let primary = preferredPrimary.map { badge in
            PersonOfficialBadge(
                title: badge.title,
                description: badge.description,
                iconURL: badgeV2?.icon.flatMap(validURL) ?? badge.iconURL,
                nightIconURL: badgeV2?.nightIcon.flatMap(validURL) ?? badge.nightIconURL,
                destinationURL: badge.destinationURL,
                typeRaw: badge.typeRaw,
                detailTypeRaw: badge.detailTypeRaw
            )
        }
        return PersonProfile(
            memberID: id,
            urlToken: urlToken?.nonBlank,
            displayName: name?.nonBlank ?? provisionalDisplayName,
            avatarURL: avatarUrl.flatMap(validURL),
            headline: headline ?? "",
            primaryOfficialBadge: primary,
            officialBadgeDetails: details,
            followerCount: followerCount ?? 0,
            followingCount: followingCount ?? 0,
            answerCount: answerCount ?? 0,
            articleCount: articlesCount ?? 0,
            isFollowing: isFollowing ?? false,
            isBlocking: isBlocking ?? false,
            memberScopedSearchID: id.nonBlank
        )
    }
}

private func validURL(_ value: String) -> URL? {
    guard let value = value.nonBlank, let url = URL(string: value) else { return nil }
    return url
}

private struct PageData<T: Decodable>: Decodable {
    let data: [T]
}

private struct AnswerResponse: Decodable {
    let id: Int64
    let question: QuestionSummary
    let excerpt: String?
    let voteupCount: Int?
    let commentCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, question, excerpt, voteupCount, commentCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleInt64(forKey: .id)
        question = try container.decode(QuestionSummary.self, forKey: .question)
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt)
        voteupCount = try container.decodeIfPresent(Int.self, forKey: .voteupCount)
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount)
    }

    struct QuestionSummary: Decodable {
        let id: Int64
        let title: String?

        private enum CodingKeys: String, CodingKey { case id, title }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeFlexibleInt64(forKey: .id)
            title = try container.decodeIfPresent(String.self, forKey: .title)
        }
    }
}

private struct ArticleResponse: Decodable {
    let id: Int64
    let title: String?
    let excerpt: String?
    let voteupCount: Int?
    let commentCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, title, excerpt, voteupCount, commentCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleInt64(forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt)
        voteupCount = try container.decodeIfPresent(Int.self, forKey: .voteupCount)
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount)
    }
}

private struct CollectionResponse: Decodable {
    let id: String
    let title: String?
    let answerCount: Int?
    let followerCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, title, answerCount, followerCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleString(forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        answerCount = try container.decodeIfPresent(Int.self, forKey: .answerCount)
        followerCount = try container.decodeIfPresent(Int.self, forKey: .followerCount)
    }
}

private struct QuestionResponse: Decodable {
    let id: Int64
    let title: String?
    let answerCount: Int?
    let followerCount: Int?

    private enum CodingKeys: String, CodingKey { case id, title, answerCount, followerCount }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleInt64(forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        answerCount = try container.decodeIfPresent(Int.self, forKey: .answerCount)
        followerCount = try container.decodeIfPresent(Int.self, forKey: .followerCount)
    }
}

private struct PinResponse: Decodable {
    let id: String
    let excerptTitle: String?
    let likeCount: Int?
    let commentCount: Int?
}

private struct ColumnResponse: Decodable {
    let id: String
    let url: String?
    let title: String?
    let description: String?
    let articlesCount: Int?
    let followerCount: Int?
    let followers: Int?
}

private struct PeopleResponse: Decodable {
    let id: String
    let urlToken: String?
    let name: String?
    let avatarUrl: String?
    let headline: String?
    let badgeV2: BadgeContainerResponse?
    let answerCount: Int?
    let articlesCount: Int?
    let followerCount: Int?
}

private struct TopicResponse: Decodable {
    let id: String?
    let name: String?
    let avatarUrl: String?
    let topic: NestedTopic?

    struct NestedTopic: Decodable {
        let id: String?
        let name: String?
        let avatarUrl: String?
    }
}

private struct FollowedQuestionResponse: Decodable {
    let id: String
    let title: String?
}

private enum PersonPageMapper {
    static func map(data: Data, key: PersonPageKey) throws -> [PersonPageItem] {
        var occurrences = OccurrenceCounter()
        switch key {
        case .main(.answers):
            return try decode(data, as: AnswerResponse.self).map { item in
                let title = try required(item.question.title)
                return .answer(
                    PersonAnswerItem(
                        id: occurrences.next(.answer, "\(item.id)", "\(item.question.id)"),
                        answerID: item.id,
                        questionID: item.question.id,
                        questionTitle: title,
                        excerpt: item.excerpt ?? "",
                        voteUpCount: item.voteupCount ?? 0,
                        commentCount: item.commentCount ?? 0
                    )
                )
            }
        case .main(.articles):
            return try decode(data, as: ArticleResponse.self).map { item in
                .article(
                    PersonArticleItem(
                        id: occurrences.next(.article, "\(item.id)", nil),
                        articleID: item.id,
                        title: try required(item.title),
                        excerpt: item.excerpt ?? "",
                        voteUpCount: item.voteupCount ?? 0,
                        commentCount: item.commentCount ?? 0
                    )
                )
            }
        case .main(.activities):
            return try activities(data)
        case .main(.collections), .subscription(.followingCollections):
            return try decode(data, as: CollectionResponse.self).map { item in
                .collection(
                    PersonCollectionItem(
                        id: occurrences.next(.collection, item.id, nil),
                        collectionID: item.id,
                        title: try required(item.title),
                        contentCount: item.answerCount ?? 0,
                        followerCount: item.followerCount ?? 0
                    )
                )
            }
        case .main(.questions):
            return try decode(data, as: QuestionResponse.self).map { item in
                .question(
                    PersonQuestionItem(
                        id: occurrences.next(.question, "\(item.id)", nil),
                        questionID: item.id,
                        title: try required(item.title),
                        answerCount: item.answerCount ?? 0,
                        followerCount: item.followerCount ?? 0
                    )
                )
            }
        case .main(.pins):
            return try decode(data, as: PinResponse.self).map { item in
                guard let pinID = Int64(item.id) else { throw PersonRepositoryError.malformedPayload }
                return .pin(
                    PersonPinItem(
                        id: occurrences.next(.pin, item.id, nil),
                        pinID: pinID,
                        excerptPlainText: plainText(item.excerptTitle ?? ""),
                        likeCount: item.likeCount ?? 0,
                        commentCount: item.commentCount ?? 0
                    )
                )
            }
        case .main(.columns), .subscription(.followingColumns):
            return try decode(data, as: ColumnResponse.self).map { item in
                .column(
                    PersonColumnItem(
                        id: occurrences.next(.column, item.id, nil),
                        columnID: item.id,
                        title: try required(item.title),
                        description: item.description?.nonBlank,
                        articleCount: item.articlesCount ?? 0,
                        followerCount: max(item.followerCount ?? 0, item.followers ?? 0),
                        destination: columnRoute(item)
                    )
                )
            }
        case .main(.followers), .main(.following):
            return try decode(data, as: PeopleResponse.self).map { item in
                guard let route = PersonRoutePayload(
                    memberID: item.id,
                    urlToken: item.urlToken,
                    displayName: try required(item.name)
                ) else { throw PersonRepositoryError.malformedPayload }
                return .person(
                    PersonListPersonItem(
                        id: occurrences.next(.person, item.id, nil),
                        route: route,
                        avatarURL: item.avatarUrl.flatMap(validURL),
                        headline: item.headline ?? "",
                        primaryOfficialBadge: primaryBadge(item.badgeV2),
                        answerCount: item.answerCount ?? 0,
                        articleCount: item.articlesCount ?? 0,
                        followerCount: item.followerCount ?? 0
                    )
                )
            }
        case .subscription(.followingTopics):
            return try decode(data, as: TopicResponse.self).map { item in
                let topicID = try required(item.topic?.id ?? item.id)
                let name = try required(item.topic?.name ?? item.name)
                let url = URL(string: "https://www.zhihu.com/topic/\(pathSegment(topicID))")
                return .topic(
                    PersonTopicItem(
                        id: occurrences.next(.topic, topicID, nil),
                        topicID: topicID,
                        displayName: name,
                        avatarURL: (item.topic?.avatarUrl ?? item.avatarUrl).flatMap(validURL),
                        destination: url.flatMap { PersonWebRoute(kind: .topic, title: name, url: $0) }
                    )
                )
            }
        case .subscription(.followingQuestions):
            return try decode(data, as: FollowedQuestionResponse.self).map { item in
                .followedQuestion(
                    PersonFollowedQuestionItem(
                        id: occurrences.next(.followedQuestion, item.id, nil),
                        rawQuestionID: item.id,
                        title: try required(item.title),
                        questionID: Int64(item.id)
                    )
                )
            }
        case .main(.subscriptions):
            throw PersonRepositoryError.invalidPage
        }
    }

    private static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> [T] {
        try JSONDecoder.person.decode(PageData<T>.self, from: data).data
    }

    private static func activities(_ data: Data) throws -> [PersonPageItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]]
        else { throw PersonRepositoryError.malformedPayload }
        var occurrences = OccurrenceCounter()
        return try rows.map { row in
            let target = row["target"] as? [String: Any]
            let question = target?["question"] as? [String: Any]
            let targetType = string(target?["type"])?.lowercased()
            let title = try required(
                string(question?["title"])
                    ?? string(target?["title"])
                    ?? string(target?["name"])
                    ?? (targetType == "pin" ? "想法" : nil)
            )
            let summary = string(target?["excerpt"])
                ?? string(target?["excerpt_title"])
                ?? string(row["brief"])
            let details = try required(
                string(row["action_text"])
                    ?? string(row["moment_desc"])
                    ?? string(row["verb"])
                    ?? string(row["target_type"])
            )
            let stableID = string(row["id"])
                ?? string(target?["id"])
                ?? "\(title)|\(details)"
            return .activity(
                PersonActivityItem(
                    id: occurrences.next(.activity, stableID, nil),
                    title: title,
                    summary: summary?.nonBlank,
                    details: details,
                    destination: activityDestination(target: target)
                )
            )
        }
    }

    private static func activityDestination(target: [String: Any]?) -> PersonNavigationIntent? {
        guard let type = string(target?["type"])?.lowercased(),
              let rawID = string(target?["id"])
        else { return nil }
        switch type {
        case "answer":
            return Int64(rawID).map { .article(.init(id: $0, kind: .answer)) }
        case "article":
            return Int64(rawID).map { .article(.init(id: $0, kind: .article)) }
        case "question":
            return Int64(rawID).map(PersonNavigationIntent.question)
        case "pin":
            return Int64(rawID).map(PersonNavigationIntent.pin)
        default:
            return nil
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string.nonBlank }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func required(_ value: String?) throws -> String {
        guard let value = value?.nonBlank else { throw PersonRepositoryError.malformedPayload }
        return value
    }

    private static func primaryBadge(_ container: BadgeContainerResponse?) -> PersonOfficialBadge? {
        let details = (container?.detailBadges ?? container?.mergedBadges ?? []).compactMap { $0.mapped() }
        return details.first { $0.typeRaw != "identity" && $0.iconURL != nil }
            ?? details.first { $0.iconURL != nil }
    }

    private static func columnRoute(_ item: ColumnResponse) -> PersonWebRoute? {
        let rawURL = item.url?.nonBlank
        let destination: URL?
        if let rawURL, rawURL.contains("/api/v4/columns/") {
            destination = URL(
                string: rawURL
                    .replacingOccurrences(of: "http://", with: "https://")
                    .replacingOccurrences(of: "/api/v4/columns/", with: "/column/")
            )
        } else if let rawURL, rawURL.hasPrefix("http"), !rawURL.contains("/api/") {
            destination = URL(string: rawURL.replacingOccurrences(of: "http://", with: "https://"))
        } else {
            destination = URL(string: "https://www.zhihu.com/column/\(pathSegment(item.id))")
        }
        guard let destination else { return nil }
        return PersonWebRoute(kind: .column, title: item.title ?? "专栏", url: destination)
    }

    private static func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .personPathSegment) ?? value
    }

    private static func plainText(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              )
        else { return html }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct OccurrenceCounter {
        private struct Base: Hashable {
            let kind: PersonListItemID.Kind
            let primaryID: String
            let contextID: String?
        }

        private var counts: [Base: Int] = [:]

        mutating func next(
            _ kind: PersonListItemID.Kind,
            _ primaryID: String,
            _ contextID: String?
        ) -> PersonListItemID {
            let base = Base(kind: kind, primaryID: primaryID, contextID: contextID)
            let occurrence = counts[base, default: 0]
            counts[base] = occurrence + 1
            return PersonListItemID(
                kind: kind,
                primaryID: primaryID,
                contextID: contextID,
                occurrence: occurrence
            )
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleInt64(forKey key: Key) throws -> Int64 {
        if let value = try? decode(Int64.self, forKey: key) {
            return value
        }
        let raw = try decode(String.self, forKey: key)
        guard let value = Int64(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected a decimal Int64 identifier"
            )
        }
        return value
    }
}
