import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum SpotlightContentDomain: String, CaseIterable, Sendable {
    case collections
    case history
    case readLater

    var domainIdentifier: String {
        "com.private.zhihu.plus.plus.search.\(rawValue)"
    }
}

enum SpotlightContentRoute: Hashable, Sendable {
    case answer(Int64)
    case article(Int64)
    case question(Int64)
    case pin(Int64)

    fileprivate var encoded: String {
        switch self {
        case let .answer(id): return "answer:\(id)"
        case let .article(id): return "article:\(id)"
        case let .question(id): return "question:\(id)"
        case let .pin(id): return "pin:\(id)"
        }
    }

    fileprivate init?(encoded: String) {
        let pieces = encoded.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2, let id = Int64(pieces[1]) else { return nil }
        switch pieces[0] {
        case "answer": self = .answer(id)
        case "article": self = .article(id)
        case "question": self = .question(id)
        case "pin": self = .pin(id)
        default: return nil
        }
    }

    var nativeDestination: NativeContentDestination {
        switch self {
        case let .answer(id): return .article(id: id, kind: .answer)
        case let .article(id): return .article(id: id, kind: .article)
        case let .question(id): return .question(id: id)
        case let .pin(id): return .pin(id: id)
        }
    }
}

struct SpotlightContentDTO: Hashable, Sendable {
    let domain: SpotlightContentDomain
    let route: SpotlightContentRoute
    let title: String
    let authorName: String?
    let summary: String?
    let updatedAt: Date?

    var uniqueIdentifier: String {
        "\(domain.domainIdentifier)|\(route.encoded)"
    }
}

extension SpotlightContentDTO {
    init?(collectionItem: NativeLibraryItem) {
        guard let route = collectionItem.destination?.spotlightRoute,
              !collectionItem.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        self.init(
            domain: .collections,
            route: route,
            title: collectionItem.title,
            authorName: collectionItem.authorName,
            summary: collectionItem.summary.nonBlank,
            updatedAt: nil
        )
    }

    init?(historyItem: NativeHistoryItem) {
        guard let route = historyItem.destination?.spotlightRoute,
              !historyItem.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        self.init(
            domain: .history,
            route: route,
            title: historyItem.title,
            authorName: historyItem.authorName,
            summary: historyItem.summary.nonBlank,
            updatedAt: historyItem.readTime > 0
                ? Date(timeIntervalSince1970: TimeInterval(historyItem.readTime))
                : nil
        )
    }
}

enum SpotlightRouteCodec {
    static func route(fromSearchableItemIdentifier identifier: String) -> SpotlightContentRoute? {
        guard let separator = identifier.lastIndex(of: "|") else { return nil }
        let domain = String(identifier[..<separator])
        guard SpotlightContentDomain.allCases.contains(where: { $0.domainIdentifier == domain }) else {
            return nil
        }
        return SpotlightContentRoute(encoded: String(identifier[identifier.index(after: separator)...]))
    }
}

enum SpotlightIndexReconciliation: Equatable {
    case unavailable
    case notConfigured
    case disabledAndDeleted
    case indexed(Int)
}

protocol SpotlightIndexWriting: Sendable {
    func isAvailable() async -> Bool
    func replace(_ items: [SpotlightContentDTO], in domain: SpotlightContentDomain) async throws
    func delete(domains: [SpotlightContentDomain]) async throws
}

actor CoreSpotlightIndexWriter: SpotlightIndexWriting {
    private let index: CSSearchableIndex

    init(index: CSSearchableIndex = .default()) {
        self.index = index
    }

    func isAvailable() async -> Bool {
        CSSearchableIndex.isIndexingAvailable()
    }

    func replace(_ items: [SpotlightContentDTO], in domain: SpotlightContentDomain) async throws {
        try await delete(domains: [domain])
        guard !items.isEmpty else { return }
        let searchableItems = items.map { item in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = item.title
            attributes.displayName = item.title
            attributes.contentDescription = item.summary
            attributes.authorNames = item.authorName.map { [$0] }
            attributes.lastUsedDate = item.updatedAt
            return CSSearchableItem(
                uniqueIdentifier: item.uniqueIdentifier,
                domainIdentifier: domain.domainIdentifier,
                attributeSet: attributes
            )
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(searchableItems) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func delete(domains: [SpotlightContentDomain]) async throws {
        guard !domains.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: domains.map(\.domainIdentifier)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

actor SpotlightIndexCoordinator {
    private let writer: SpotlightIndexWriting

    init(writer: SpotlightIndexWriting = CoreSpotlightIndexWriter()) {
        self.writer = writer
    }

    func reconcile(
        preference: Bool?,
        snapshots: [SpotlightContentDomain: [SpotlightContentDTO]]
    ) async throws -> SpotlightIndexReconciliation {
        guard await writer.isAvailable() else { return .unavailable }
        guard let preference else { return .notConfigured }
        guard preference else {
            try await writer.delete(domains: SpotlightContentDomain.allCases)
            return .disabledAndDeleted
        }

        var indexedCount = 0
        for domain in SpotlightContentDomain.allCases {
            let items = snapshots[domain, default: []].filter { $0.domain == domain }
            try await writer.replace(items, in: domain)
            indexedCount += items.count
        }
        return .indexed(indexedCount)
    }
}

private extension NativeContentDestination {
    var spotlightRoute: SpotlightContentRoute? {
        switch self {
        case let .article(id, kind):
            return kind == .answer ? .answer(id) : .article(id)
        case let .question(id):
            return .question(id)
        case let .pin(id):
            return .pin(id)
        case .person, .search, .external:
            return nil
        }
    }
}

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
