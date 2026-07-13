import CryptoKit
import Foundation
import UIKit

struct CommentPageResult {
    let items: [CommentDTO]
    let nextURL: URL?
    let isEnd: Bool
}

protocol CommentRepository {
    func fetchPage(
        route: CommentThreadRouteDTO,
        level: CommentLevelKey,
        sort: CommentSortDTO,
        nextURL: URL?
    ) async throws -> CommentPageResult
    func setLiked(_ target: Bool, commentID: String) async throws
    func submit(_ snapshot: CommentSubmissionSnapshotDTO) async throws -> CommentDTO
}

protocol CommentAuthorBlocking: Sendable {
    func blockedMemberIDs() async -> Set<String>
}

struct NoBlockedCommentAuthors: CommentAuthorBlocking {
    func blockedMemberIDs() async -> Set<String> { [] }
}

actor URLSessionCommentRepository: CommentRepository {
    private static let inlineReplyPageSize = "5"

    private let client: ZhihuAPIClient
    private let authorBlocking: CommentAuthorBlocking
    private let imageUploadSession: URLSession

    init(
        client: ZhihuAPIClient,
        authorBlocking: CommentAuthorBlocking = NoBlockedCommentAuthors(),
        imageUploadSession: URLSession = .shared
    ) {
        self.client = client
        self.authorBlocking = authorBlocking
        self.imageUploadSession = imageUploadSession
    }

    func fetchPage(
        route: CommentThreadRouteDTO,
        level: CommentLevelKey,
        sort: CommentSortDTO,
        nextURL: URL?
    ) async throws -> CommentPageResult {
        let candidateURL = try nextURL.map(validatedContinuationURL) ?? initialURL(
            route: route,
            level: level,
            sort: sort
        )
        let url = try applyingInlineReplyPageSize(to: candidateURL, level: level)
        let data = try await client.data(for: url, authentication: .accountRequired)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawData = root["data"] as? [Any]
        else { throw CommentRepositoryError.malformedPayload }
        let comments = rawData.compactMap { item -> CommentResponse? in
            guard JSONSerialization.isValidJSONObject(item),
                  let itemData = try? JSONSerialization.data(withJSONObject: item),
                  let comment = try? JSONDecoder.comment.decode(CommentResponse.self, from: itemData)
            else { return nil }
            return comment
        }
        let paging: CommentPagingResponse?
        if let rawPaging = root["paging"], JSONSerialization.isValidJSONObject(rawPaging) {
            let pagingData = try JSONSerialization.data(withJSONObject: rawPaging)
            paging = try JSONDecoder.comment.decode(CommentPagingResponse.self, from: pagingData)
        } else {
            paging = nil
        }
        let blocked = await authorBlocking.blockedMemberIDs()
        let items = comments.compactMap { raw -> CommentDTO? in
            guard !blocked.contains(raw.author.id) else { return nil }
            return raw.dto(blockedMemberIDs: blocked)
        }
        let next = try paging?.next
            .flatMap(URL.init(string:))
            .map(validatedContinuationURL)
        return CommentPageResult(
            items: unique(items),
            nextURL: next,
            isEnd: paging?.isEnd ?? true
        )
    }

    func setLiked(_ target: Bool, commentID: String) async throws {
        let encodedID = try pathSegment(commentID)
        let url = try requiredURL("https://www.zhihu.com/api/v4/comments/\(encodedID)/like")
        _ = try await client.data(
            for: url,
            method: target ? "POST" : "DELETE",
            authentication: .accountRequired
        )
    }

    func submit(_ snapshot: CommentSubmissionSnapshotDTO) async throws -> CommentDTO {
        let url = try submissionURL(subject: snapshot.subject)
        let imageURL: URL?
        if let imageData = snapshot.imageData {
            imageURL = try await uploadCommentImage(imageData)
        } else {
            imageURL = nil
        }
        var payload: [String: String] = [
            "content": CommentSubmissionHTML.make(text: snapshot.text, imageURL: imageURL),
        ]
        if let replyToCommentID = snapshot.replyToCommentID {
            payload["reply_comment_id"] = replyToCommentID
        }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let data = try await client.data(
            for: url,
            method: "POST",
            body: body,
            additionalHeaders: ["Content-Type": "application/json"],
            authentication: .accountRequired
        )
        let raw = try JSONDecoder.comment.decode(CommentResponse.self, from: data)
        let blocked = await authorBlocking.blockedMemberIDs()
        guard !blocked.contains(raw.author.id) else {
            throw CommentRepositoryError.blockedSubmittedAuthor
        }
        return raw.dto(blockedMemberIDs: blocked)
    }

    private func uploadCommentImage(_ sourceData: Data) async throws -> URL {
        guard let sourceImage = UIImage(data: sourceData),
              let jpegData = sourceImage.jpegData(compressionQuality: 0.9)
        else { throw CommentRepositoryError.invalidImage }
        let imageHash = Insecure.MD5.hash(data: jpegData).map { String(format: "%02x", $0) }.joined()
        let applyURL = try requiredURL("https://api.zhihu.com/images")
        let applyBody = try JSONSerialization.data(withJSONObject: [
            "image_hash": imageHash,
            "source": "article",
        ], options: [.sortedKeys])
        let applyData = try await client.data(
            for: applyURL,
            method: "POST",
            body: applyBody,
            additionalHeaders: ["Content-Type": "application/json"],
            authentication: .accountRequired
        )
        let apply = try JSONDecoder.comment.decode(CommentImageApplyResponse.self, from: applyData)
        if apply.uploadFile.state == 2 {
            guard let token = apply.uploadToken else { throw CommentRepositoryError.malformedImageUpload }
            try await uploadImageData(jpegData, hash: imageHash, token: token)
            let statusURL = try requiredURL(
                "https://api.zhihu.com/images/\(try pathSegment(apply.uploadFile.imageId))/uploading_status"
            )
            let statusBody = Data(#"{"upload_result":"success"}"#.utf8)
            _ = try await client.data(
                for: statusURL,
                method: "PUT",
                body: statusBody,
                additionalHeaders: ["Content-Type": "application/json"],
                authentication: .accountRequired
            )
        }
        return try await resolvedImageURL(imageID: apply.uploadFile.imageId)
    }

    private func uploadImageData(_ data: Data, hash: String, token: CommentImageUploadToken) async throws {
        let date = CommentImageUploadSigner.rfc1123Date()
        let userAgent = CommentImageUploadSigner.ossUserAgent
        let signature = CommentImageUploadSigner.signature(
            mimeType: "image/jpeg",
            date: date,
            token: token,
            imageHash: hash
        )
        guard let url = URL(string: "https://zhihu-pics-upload.zhimg.com/v2-\(hash)") else {
            throw CommentRepositoryError.malformedImageUpload
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(date, forHTTPHeaderField: "x-oss-date")
        request.setValue(userAgent, forHTTPHeaderField: "x-oss-user-agent")
        request.setValue(token.accessToken, forHTTPHeaderField: "x-oss-security-token")
        request.setValue("OSS \(token.accessId):\(signature)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await imageUploadSession.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == "zhihu-pics-upload.zhimg.com",
              (200..<300).contains(response.statusCode)
        else { throw CommentRepositoryError.imageUploadFailed }
    }

    private func resolvedImageURL(imageID: String) async throws -> URL {
        let encodedID = try pathSegment(imageID)
        let url = try requiredURL("https://api.zhihu.com/images/\(encodedID)")
        for attempt in 0..<8 {
            let data = try await client.data(for: url, authentication: .accountRequired)
            let status = try JSONDecoder.comment.decode(CommentImageStatus.self, from: data)
            if status.status == "success",
               let value = status.originalSrc ?? status.src ?? status.watermarkSrc,
               let resolved = CommentURLPolicy.remoteImageURL(value) {
                return resolved
            }
            if attempt < 7 { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        throw CommentRepositoryError.imageUploadFailed
    }

    private func initialURL(
        route: CommentThreadRouteDTO,
        level: CommentLevelKey,
        sort: CommentSortDTO
    ) throws -> URL {
        switch level {
        case .root:
            guard var components = URLComponents(
                url: try rootURL(subject: route.subject),
                resolvingAgainstBaseURL: false
            ) else { throw CommentRepositoryError.invalidURL }
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "order_by", value: sort.queryValue))
            components.queryItems = queryItems
            guard let url = components.url else { throw CommentRepositoryError.invalidURL }
            return url
        case let .replies(rootCommentID):
            let id = try pathSegment(rootCommentID)
            return try requiredURL("https://www.zhihu.com/api/v4/comment_v5/comment/\(id)/child_comment")
        }
    }

    private func applyingInlineReplyPageSize(to url: URL, level: CommentLevelKey) throws -> URL {
        guard case .replies = level,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "limit" }
        queryItems.append(URLQueryItem(name: "limit", value: Self.inlineReplyPageSize))
        components.queryItems = queryItems
        guard let sizedURL = components.url else { throw CommentRepositoryError.invalidURL }
        return sizedURL
    }

    private func rootURL(subject: CommentSubjectDTO) throws -> URL {
        switch subject {
        case let .answer(id):
            return try requiredURL("https://www.zhihu.com/api/v4/comment_v5/answers/\(id)/root_comment")
        case let .article(id):
            return try requiredURL("https://www.zhihu.com/api/v4/comment_v5/articles/\(id)/root_comment")
        case let .question(id):
            return try requiredURL("https://www.zhihu.com/api/v4/comment_v5/questions/\(id)/root_comment")
        case let .pin(id):
            return try requiredURL("https://www.zhihu.com/api/v4/comment_v5/pins/\(id)/root_comment")
        case let .segment(contentID, contentTypeRaw, segmentID):
            let content = try pathSegment(contentID)
            let type = try pathSegment(contentTypeRaw.removingOneTrailingS)
            guard var components = URLComponents(
                string: "https://www.zhihu.com/api/v4/comment_v5/\(type)s/\(content)/segment/root_comment"
            ) else { throw CommentRepositoryError.invalidURL }
            components.queryItems = [
                URLQueryItem(name: "segment_id", value: segmentID),
                URLQueryItem(name: "limit", value: "20"),
                URLQueryItem(name: "offset", value: ""),
            ]
            guard let url = components.url else { throw CommentRepositoryError.invalidURL }
            return url
        }
    }

    private func submissionURL(subject: CommentSubjectDTO) throws -> URL {
        switch subject {
        case let .answer(id):
            return try requiredURL("https://www.zhihu.com/api/v4/comment_v5/answers/\(id)/comment")
        case let .article(id):
            return try requiredURL("https://www.zhihu.com/api/v4/comment_v5/articles/\(id)/comment")
        case let .question(id):
            return try requiredURL("https://www.zhihu.com/api/v4/comment_v5/questions/\(id)/comment")
        case let .pin(id):
            return try requiredURL("https://www.zhihu.com/api/v4/comment_v5/pins/\(id)/comment")
        case let .segment(contentID, contentTypeRaw, segmentID):
            let content = try pathSegment(contentID)
            let type = try pathSegment(contentTypeRaw.removingOneTrailingS)
            guard var components = URLComponents(
                string: "https://www.zhihu.com/api/v4/comment_v5/\(type)s/\(content)/segment/comment"
            ) else { throw CommentRepositoryError.invalidURL }
            components.queryItems = [URLQueryItem(name: "segment_id", value: segmentID)]
            guard let url = components.url else { throw CommentRepositoryError.invalidURL }
            return url
        }
    }

    private func validatedContinuationURL(_ source: URL) throws -> URL {
        let url: URL
        if source.scheme?.lowercased() == "http",
           var components = URLComponents(url: source, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            url = components.url ?? source
        } else {
            url = source
        }
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              host == "www.zhihu.com" || host == "api.zhihu.com",
              url.path.hasPrefix("/api/v4/comment_v5/")
        else {
            throw CommentRepositoryError.untrustedContinuation
        }
        return url
    }

    private func requiredURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw CommentRepositoryError.invalidURL }
        return url
    }

    private func pathSegment(_ value: String) throws -> String {
        guard !value.isEmpty,
              let result = value.addingPercentEncoding(withAllowedCharacters: .commentPathSegment)
        else { throw CommentRepositoryError.invalidURL }
        return result
    }

    private func unique(_ comments: [CommentDTO]) -> [CommentDTO] {
        var seen = Set<String>()
        return comments.filter { seen.insert($0.id).inserted }
    }
}

enum CommentRepositoryError: LocalizedError {
    case invalidURL
    case untrustedContinuation
    case malformedPayload
    case blockedSubmittedAuthor
    case invalidImage
    case malformedImageUpload
    case imageUploadFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "评论请求地址无效"
        case .untrustedContinuation: return "评论分页地址不可信"
        case .malformedPayload: return "评论数据格式无法识别"
        case .blockedSubmittedAuthor: return "评论已发送，但当前过滤规则不显示该内容"
        case .invalidImage: return "无法读取选择的图片"
        case .malformedImageUpload: return "图片上传凭据无效，请稍后重试"
        case .imageUploadFailed: return "图片上传失败，请稍后重试"
        }
    }
}

enum CommentSubmissionHTML {
    static func make(text: String, imageURL: URL?) -> String {
        var fragments: [String] = []
        if !text.isEmpty {
            fragments.append("<p>\(text.escapedForCommentHTML)</p>")
        }
        if let imageURL {
            fragments.append(
                #"<a class="comment_img" href="\#(imageURL.absoluteString.escapedForCommentHTML)">[图片]</a>"#
            )
        }
        return fragments.joined()
    }
}

private struct CommentImageApplyResponse: Decodable {
    let uploadFile: CommentImageUploadFile
    let uploadToken: CommentImageUploadToken?
}

private struct CommentImageUploadFile: Decodable {
    let imageId: String
    let state: Int
}

private struct CommentImageUploadToken: Decodable {
    let accessId: String
    let accessKey: String
    let accessToken: String
}

private struct CommentImageStatus: Decodable {
    let status: String?
    let src: String?
    let originalSrc: String?
    let watermarkSrc: String?
}

private enum CommentImageUploadSigner {
    static let ossUserAgent = "aliyun-sdk-js/6.8.0 Chrome 99.0.4844.84 on Windows 10 64-bit"

    static func rfc1123Date(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    static func signature(
        mimeType: String,
        date: String,
        token: CommentImageUploadToken,
        imageHash: String
    ) -> String {
        let message = """
        PUT

        \(mimeType)
        \(date)
        x-oss-date:\(date)
        x-oss-security-token:\(token.accessToken)
        x-oss-user-agent:\(ossUserAgent)
        /zhihu-pics/v2-\(imageHash)
        """
        let key = SymmetricKey(data: Data(token.accessKey.utf8))
        let authentication = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(message.utf8),
            using: key
        )
        return Data(authentication).base64EncodedString()
    }
}

private extension CharacterSet {
    static let commentPathSegment = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )
}

private extension String {
    var removingOneTrailingS: String {
        hasSuffix("s") ? String(dropLast()) : self
    }

    var escapedForCommentHTML: String {
        reduce(into: "") { result, character in
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
    }
}

private extension JSONDecoder {
    static var comment: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private struct CommentPagingResponse: Decodable {
    let isEnd: Bool
    let next: String?
}

private struct CommentResponse: Decodable {
    let id: String
    let content: String
    let createdTime: Int64
    let author: Author
    let replyToAuthor: Author?
    let liked: Bool?
    let likeCount: Int?
    let childCommentCount: Int?
    let childComments: [CommentResponse]?

    struct Author: Decodable {
        let id: String
        let urlToken: String?
        let name: String
        let avatarUrl: String?

        var dto: CommentAuthorDTO {
            CommentAuthorDTO(
                memberID: id,
                urlToken: urlToken ?? "",
                displayName: name,
                avatarURL: avatarUrl.flatMap(CommentURLPolicy.remoteImageURL)
            )
        }
    }

    func dto(blockedMemberIDs: Set<String>) -> CommentDTO {
        let projection = CommentHTMLMediaParser.project(content)
        return CommentDTO(
            id: id,
            contentHTML: content,
            createdTimeSeconds: createdTime,
            author: author.dto,
            replyToAuthor: replyToAuthor?.dto,
            isLiked: liked ?? false,
            likeCount: likeCount ?? 0,
            childCommentCount: childCommentCount ?? 0,
            embeddedReplies: (childComments ?? [])
                .filter { !blockedMemberIDs.contains($0.author.id) }
                .map { $0.dto(blockedMemberIDs: blockedMemberIDs) },
            media: projection.media
        )
    }
}

enum CommentURLPolicy {
    static func remoteImageURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}

enum CommentHTMLMediaParser {
    struct Projection {
        let textHTML: String
        let media: [CommentMediaDTO]
    }

    static func project(_ html: String) -> Projection {
        guard let anchorExpression = try? NSRegularExpression(
            pattern: #"<a\b[^>]*>[\s\S]*?</a>"#,
            options: [.caseInsensitive]
        ) else {
            return Projection(textHTML: html, media: [])
        }
        let source = html as NSString
        let matches = anchorExpression.matches(
            in: html,
            range: NSRange(location: 0, length: source.length)
        )
        var media: [CommentMediaDTO] = []
        var textHTML = html
        for match in matches.reversed() {
            let anchor = source.substring(with: match.range)
            guard let kind = mediaKind(in: anchor),
                  let href = attribute("href", in: anchor),
                  let url = CommentURLPolicy.remoteImageURL(href)
            else { continue }
            media.insert(CommentMediaDTO(kind: kind, url: url), at: 0)
            if let swiftRange = Range(match.range, in: textHTML) {
                textHTML.removeSubrange(swiftRange)
            }
        }
        var seen = Set<String>()
        return Projection(
            textHTML: textHTML,
            media: media.filter { seen.insert($0.id).inserted }
        )
    }

    private static func mediaKind(in anchor: String) -> CommentMediaKind? {
        guard let classes = attribute("class", in: anchor)?.lowercased() else { return nil }
        let tokens = Set(classes.split(whereSeparator: \.isWhitespace).map(String.init))
        if tokens.contains("comment_img") { return .image }
        if tokens.contains("comment_gif") { return .animatedImage }
        if tokens.contains("comment_sticker") { return .sticker }
        return nil
    }

    private static func attribute(_ name: String, in source: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*([\"'])(.*?)\1"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(location: 0, length: (source as NSString).length)
        guard let match = expression.firstMatch(in: source, range: range), match.numberOfRanges > 2 else {
            return nil
        }
        return (source as NSString).substring(with: match.range(at: 2))
    }
}
