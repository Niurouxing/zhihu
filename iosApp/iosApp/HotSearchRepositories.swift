import Foundation

protocol HotFeedRepository {
    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO
}

actor URLSessionHotFeedRepository: HotFeedRepository {
    private static let initialURL = URL(
        string: "https://www.zhihu.com/api/v3/feed/topstory/hot-lists/total?limit=50&mobile=true"
    )!
    private static let include = "data[*].content,excerpt,headline,target.author.badge_v2"

    private let client: ZhihuAPIClient

    init(client: ZhihuAPIClient) {
        self.client = client
    }

    init(accountStore: AccountJSONStore, session: URLSession? = nil) {
        client = ZhihuAPIClient(accountStore: accountStore, session: session)
    }

    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO {
        let baseURL = try ZhihuAPIURLPolicy.validatedPagingURL(nextURL) ?? Self.initialURL
        let url = try addingInclude(Self.include, to: baseURL)
        let data = try await client.data(for: url, authentication: .accountIfAvailable)
        return try FeedResponseMapper.page(from: data, policy: .hot)
    }
}

protocol SearchRepository {
    func fetchSuggestions() async throws -> [SearchSuggestionDTO]
    func fetchPage(criteria: SearchCriteria, after nextURL: URL?) async throws -> FeedPageDTO
}

actor URLSessionSearchRepository: SearchRepository {
    private static let suggestionsURL = URL(string: "https://www.zhihu.com/api/v4/search/hot_search")!
    private static let include = "data[*].highlight,object,type"
    private static let verticalInfo = "0,0,0,0,0,0,0,0,0,0,0,0"

    private let client: ZhihuAPIClient

    init(client: ZhihuAPIClient) {
        self.client = client
    }

    init(accountStore: AccountJSONStore, session: URLSession? = nil) {
        client = ZhihuAPIClient(accountStore: accountStore, session: session)
    }

    func fetchSuggestions() async throws -> [SearchSuggestionDTO] {
        let data = try await client.data(for: Self.suggestionsURL, authentication: .accountRequired)
        return try FeedResponseMapper.suggestions(from: data)
    }

    func fetchPage(criteria: SearchCriteria, after nextURL: URL?) async throws -> FeedPageDTO {
        guard !criteria.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ZhihuAPIError.malformedPayload
        }
        let baseURL: URL
        if let nextURL {
            guard let validated = try ZhihuAPIURLPolicy.validatedPagingURL(nextURL) else {
                throw ZhihuAPIError.untrustedURL
            }
            baseURL = validated
        } else {
            baseURL = try initialURL(criteria: criteria)
        }
        let url = try addingInclude(Self.include, to: baseURL)
        let data = try await client.data(for: url, authentication: .accountRequired)
        return try FeedResponseMapper.page(from: data, policy: .search)
    }

    private func initialURL(criteria: SearchCriteria) throws -> URL {
        var parameters: [(String, String)] = [
            ("gk_version", "gz-gaokao"),
            ("t", "general"),
            ("q", criteria.query),
            ("correction", "1"),
            ("offset", "0"),
            ("limit", "20"),
            ("search_source", criteria.hasActiveFilter ? "Filter" : "Normal"),
            ("show_all_topics", "0"),
        ]
        if let memberHashID = criteria.restrictedMemberHashID?.trimmedNonEmpty {
            parameters.append(contentsOf: [
                ("filter_fields", ""),
                ("lc_idx", "0"),
                ("restricted_scene", "member"),
                ("restricted_field", "member_hash_id"),
                ("restricted_value", memberHashID),
            ])
        }
        if let contentType = criteria.contentType.requestValue {
            parameters.append(("vertical", contentType))
            parameters.append(("vertical_info", Self.verticalInfo))
        }
        if let sort = criteria.sort.requestValue {
            parameters.append(("sort", sort))
        }
        if let timeRange = criteria.timeRange.requestValue {
            parameters.append(("time_interval", timeRange))
        }
        let query = parameters.map { "\(formEncoded($0))=\(formEncoded($1))" }.joined(separator: "&")
        guard let url = URL(string: "https://www.zhihu.com/api/v4/search_v3?\(query)") else {
            throw ZhihuAPIError.malformedPayload
        }
        return url
    }
}

private func addingInclude(_ include: String, to url: URL) throws -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw ZhihuAPIError.malformedPayload
    }
    let encoded = "include=\(formEncoded(include))"
    if let query = components.percentEncodedQuery, !query.isEmpty {
        let hasInclude = query.split(separator: "&").contains { $0.hasPrefix("include=") }
        if !hasInclude { components.percentEncodedQuery = "\(query)&\(encoded)" }
    } else {
        components.percentEncodedQuery = encoded
    }
    guard let result = components.url else { throw ZhihuAPIError.malformedPayload }
    return result
}

private func formEncoded(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return value
        .addingPercentEncoding(withAllowedCharacters: allowed)?
        .replacingOccurrences(of: "%20", with: "+") ?? value
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
