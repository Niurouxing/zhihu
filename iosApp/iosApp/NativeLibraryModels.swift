import Foundation

enum NativeContentDestination: Equatable, Hashable {
    enum ArticleKind: String, Equatable, Hashable {
        case answer
        case article
    }

    case article(id: Int64, kind: ArticleKind)
    case question(id: Int64)
    case person(id: String, urlToken: String, name: String)
    case pin(id: Int64)
    case search(query: String)
    case external(URL)
}

enum NativeContentDestinationResolver {
    static func resolve(_ rawURL: String?) -> NativeContentDestination? {
        guard let rawURL, let url = URL(string: rawURL), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let segments = url.path.split(separator: "/").map(String.init)
        if scheme == "zhihu" {
            switch url.host?.lowercased() {
            case "answers": return segments.first.flatMap(Int64.init).map { .article(id: $0, kind: .answer) }
            case "questions": return segments.first.flatMap(Int64.init).map(NativeContentDestination.question)
            case "articles": return segments.first.flatMap(Int64.init).map { .article(id: $0, kind: .article) }
            case "pin": return segments.first.flatMap(Int64.init).map(NativeContentDestination.pin)
            case "search":
                let query = components?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
                return .search(query: query)
            default: return nil
            }
        }
        guard scheme == "https", let host = url.host?.lowercased() else { return nil }
        if host == "link.zhihu.com",
           let target = components?.queryItems?.first(where: { $0.name == "target" })?.value {
            return resolve(target)
        }
        if host == "zhuanlan.zhihu.com", segments.count == 2, segments[0] == "p",
           let id = Int64(segments[1]) {
            return .article(id: id, kind: .article)
        }
        if host == "zhihu.com" || host == "www.zhihu.com" {
            if segments.count == 4, segments[0] == "question", segments[2] == "answer",
               let id = Int64(segments[3]) {
                return .article(id: id, kind: .answer)
            }
            if segments.count == 2, segments[0] == "answer", let id = Int64(segments[1]) {
                return .article(id: id, kind: .answer)
            }
            if segments.count == 2, segments[0] == "question", let id = Int64(segments[1]) {
                return .question(id: id)
            }
            if segments.count == 3, segments[0] == "oia", segments[1] == "articles",
               let id = Int64(segments[2]) {
                return .article(id: id, kind: .article)
            }
            if segments.count == 2, segments[0] == "people" {
                let token = segments[1]
                let isMemberID = token.count == 32 && token.allSatisfy { $0.isHexDigit }
                return .person(id: isMemberID ? token : "", urlToken: token, name: "")
            }
            if segments.count == 2, segments[0] == "pin", let id = Int64(segments[1]) {
                return .pin(id: id)
            }
            if segments.count == 1, segments[0] == "search" {
                let query = components?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
                return .search(query: query)
            }
        }
        return ZhihuAPIURLPolicy.allows(url) ? .external(url) : nil
    }
}

struct NativeLibraryCollection: Identifiable, Equatable, Hashable, Decodable {
    let id: String
    let title: String
    let description: String
    let itemCount: Int
    let likeCount: Int
    let commentCount: Int
    let updatedTime: Int64
    let isPublic: Bool

    init(
        id: String,
        title: String,
        description: String = "",
        itemCount: Int = 0,
        likeCount: Int = 0,
        commentCount: Int = 0,
        updatedTime: Int64 = 0,
        isPublic: Bool = false
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.itemCount = itemCount
        self.likeCount = likeCount
        self.commentCount = commentCount
        self.updatedTime = updatedTime
        self.isPublic = isPublic
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, description
        case itemCount = "item_count"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case updatedTime = "updated_time"
        case isPublic = "is_public"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleString(forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
        likeCount = try container.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        updatedTime = try container.decodeIfPresent(Int64.self, forKey: .updatedTime) ?? 0
        isPublic = try container.decodeIfPresent(Bool.self, forKey: .isPublic) ?? false
    }
}

struct NativeLibraryItem: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let summary: String
    let detail: String
    let authorName: String?
    let avatarURL: URL?
    let destination: NativeContentDestination?
}

struct NativeHistoryItem: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let summary: String
    let detail: String
    let authorName: String?
    let coverURL: URL?
    let readTime: Int64
    let destination: NativeContentDestination?
}

struct NativePaging: Equatable {
    let next: URL?
    let isEnd: Bool
}

struct NativePage<Item: Equatable>: Equatable {
    let items: [Item]
    let paging: NativePaging
}

struct NativeLossyDecoded<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) { return string }
        if let integer = try? decode(Int64.self, forKey: key) { return String(integer) }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected string or integer identifier")
        )
    }
}
