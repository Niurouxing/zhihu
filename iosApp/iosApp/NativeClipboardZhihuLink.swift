import Foundation
import UIKit

struct NativeClipboardZhihuLinkCandidate: Identifiable, Equatable {
    let url: URL
    let destination: NativeContentDestination
    let contentKey: String

    var id: String { contentKey }
}

enum NativeClipboardZhihuLinkParser {
    static func candidate(from rawValue: String?) -> NativeClipboardZhihuLinkCandidate? {
        guard let rawValue,
              let detector = try? NSDataDetector(
                  types: NSTextCheckingResult.CheckingType.link.rawValue
              )
        else { return nil }
        let range = NSRange(rawValue.startIndex..., in: rawValue)
        for match in detector.matches(in: rawValue, range: range) {
            guard let url = match.url,
                  let destination = NativeContentDestinationResolver.resolve(url.absoluteString),
                  let contentKey = nativeContentKey(destination)
            else { continue }
            return NativeClipboardZhihuLinkCandidate(
                url: url,
                destination: destination,
                contentKey: contentKey
            )
        }
        return nil
    }

    private static func nativeContentKey(_ destination: NativeContentDestination) -> String? {
        switch destination {
        case let .article(id, kind):
            return "\(kind.rawValue):\(id)"
        case let .question(id):
            return "question:\(id)"
        case let .person(id, token, _):
            let identity = token.isEmpty ? id : token
            return identity.isEmpty ? nil : "person:\(identity)"
        case let .pin(id):
            return "pin:\(id)"
        case let .special(id):
            return "special:\(id)"
        case let .column(id):
            return "column:\(id)"
        case let .search(query):
            return query.isEmpty ? nil : "search:\(query)"
        case .external:
            return nil
        }
    }
}

struct NativeClipboardPromptHistory {
    static let defaultKey = "nativeClipboardPromptedZhihuContent"
    static let maximumCount = 40

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func contains(_ contentKey: String) -> Bool {
        defaults.stringArray(forKey: key)?.contains(contentKey) == true
    }

    func record(_ contentKey: String) {
        var values = defaults.stringArray(forKey: key) ?? []
        values.removeAll { $0 == contentKey }
        values.append(contentKey)
        if values.count > Self.maximumCount {
            values.removeFirst(values.count - Self.maximumCount)
        }
        defaults.set(values, forKey: key)
    }
}

@MainActor
final class NativeClipboardZhihuLinkMonitor: ObservableObject {
    @Published var candidate: NativeClipboardZhihuLinkCandidate?

    private let pasteboard: UIPasteboard
    private let history: NativeClipboardPromptHistory
    private var inspectedChangeCount: Int?
    private var isInspecting = false

    init(
        pasteboard: UIPasteboard = .general,
        defaults: UserDefaults = .standard
    ) {
        self.pasteboard = pasteboard
        history = NativeClipboardPromptHistory(defaults: defaults)
    }

    func inspectIfNeeded() async {
        let changeCount = pasteboard.changeCount
        guard !isInspecting,
              inspectedChangeCount != changeCount,
              candidate == nil
        else { return }
        inspectedChangeCount = changeCount
        isInspecting = true
        defer { isInspecting = false }

        guard await containsProbableWebURL(),
              !Task.isCancelled,
              let candidate = NativeClipboardZhihuLinkParser.candidate(
                  from: pasteboard.url?.absoluteString ?? pasteboard.string
              ),
              !history.contains(candidate.contentKey)
        else { return }
        history.record(candidate.contentKey)
        self.candidate = candidate
    }

    func recordAsHandled(_ url: URL) {
        guard let candidate = NativeClipboardZhihuLinkParser.candidate(
            from: url.absoluteString
        ) else { return }
        history.record(candidate.contentKey)
        inspectedChangeCount = pasteboard.changeCount
    }

    private func containsProbableWebURL() async -> Bool {
        guard let patterns = try? await pasteboard.detectedPatterns(
            for: [\UIPasteboard.DetectedValues.probableWebURL]
        ) else { return false }
        return !patterns.isEmpty
    }
}
