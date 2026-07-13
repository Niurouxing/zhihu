import Foundation

protocol HomeFeedRepository: Sendable {
    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO
    func reportOpened(_ item: FeedItemDTO) async
}

actor URLSessionHomeFeedRepository: HomeFeedRepository {
    private static let initialURL = URL(string: "https://api.zhihu.com/topstory/recommend?limit=20")!
    private static let touchURL = URL(string: "https://www.zhihu.com/lastread/touch")!

    private let client: ZhihuAPIClient

    init(client: ZhihuAPIClient) {
        self.client = client
    }

    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO {
        let baseURL = try ZhihuAPIURLPolicy.validatedPagingURL(nextURL) ?? Self.initialURL
        let url = try HomeFollowRequestURL.addingFeedParameters(to: baseURL)
        let data = try await client.data(for: url, authentication: .accountIfAvailable)
        return try FeedResponseMapper.page(from: data, policy: .search)
    }

    func reportOpened(_ item: FeedItemDTO) async {
        guard item.kind == .answer || item.kind == .article || item.kind == .pin else { return }
        let payload = "[[\"\(item.kind.rawValue)\",\"\(item.id.contentID)\",\"read\"]]"
        let boundary = "ZhihuPlus-\(UUID().uuidString)"
        let body = Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"items\"\r\n\r\n\(payload)\r\n--\(boundary)--\r\n".utf8
        )
        _ = try? await client.data(
            for: Self.touchURL,
            method: "POST",
            body: body,
            additionalHeaders: [
                "Content-Type": "multipart/form-data; boundary=\(boundary)",
                "x-requested-with": "fetch",
            ],
            authentication: .accountRequired
        )
    }
}

protocol FollowRepository: Sendable {
    func fetchPage(section: FollowSection, after nextURL: URL?) async throws -> FeedPageDTO
    func fetchRecentUsers() async throws -> [FollowingUserDTO]
}

actor URLSessionFollowRepository: FollowRepository {
    private static let recommendationURL = URL(string: "https://api.zhihu.com/moments_v3?feed_type=recommend&limit=20")!
    private static let momentsURL = URL(string: "https://www.zhihu.com/api/v3/moments?limit=20&desktop=true")!
    private static let recentURL = URL(string: "https://api.zhihu.com/moments/recent?type=raw")!

    private let client: ZhihuAPIClient

    init(client: ZhihuAPIClient) {
        self.client = client
    }

    func fetchPage(section: FollowSection, after nextURL: URL?) async throws -> FeedPageDTO {
        let initial = section == .recommendations ? Self.recommendationURL : Self.momentsURL
        let baseURL = try ZhihuAPIURLPolicy.validatedPagingURL(nextURL) ?? initial
        let url = try HomeFollowRequestURL.addingFeedParameters(to: baseURL)
        let data = try await client.data(for: url, authentication: .accountRequired)
        return try FeedResponseMapper.page(from: data, policy: .search)
    }

    func fetchRecentUsers() async throws -> [FollowingUserDTO] {
        let data = try await client.data(for: Self.recentURL, authentication: .accountRequired)
        return try HomeFollowResponseMapper.followingUsers(from: data)
    }
}

enum HomeFollowRequestURL {
    private static let include = "data[*].content,excerpt,headline,target.author.badge_v2"
    private static let pageSize = "20"

    static func addingFeedParameters(to url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ZhihuAPIError.malformedPayload
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "include" }) {
            items.append(URLQueryItem(name: "include", value: include))
        }
        items.removeAll(where: { $0.name == "limit" })
        items.append(URLQueryItem(name: "limit", value: pageSize))
        components.queryItems = items
        guard let result = components.url else { throw ZhihuAPIError.malformedPayload }
        return result
    }
}

enum HomeFollowResponseMapper {
    static func followingUsers(from data: Data) throws -> [FollowingUserDTO] {
        let root = try jsonObject(data)
        return (root["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let actor = item["actor"] as? [String: Any],
                  let id = (actor["id"] as? String)?.nonBlank,
                  let token = (actor["url_token"] as? String ?? actor["urlToken"] as? String)?.nonBlank,
                  let name = (actor["name"] as? String)?.nonBlank
            else { return nil }
            return FollowingUserDTO(
                id: id,
                urlToken: token,
                displayName: name,
                avatarURL: (actor["avatar_url"] as? String ?? actor["avatarUrl"] as? String).flatMap(httpsURL),
                unreadCount: max(0, item["unread_count"] as? Int ?? item["unreadCount"] as? Int ?? 0)
            )
        }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZhihuAPIError.malformedPayload
        }
        return root
    }
}

private func httpsURL(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme?.lowercased() == "https" else { return nil }
    return url
}

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
