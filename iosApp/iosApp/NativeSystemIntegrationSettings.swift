import AVFAudio
import Foundation
import UIKit

@MainActor
final class NativeSystemIntegrationSettings: ObservableObject {
    enum Key {
        static let spotlightIndexing = "nativeSystem.spotlightIndexing"
        static let appLock = "nativeSystem.appLock"
        static let translationTargetLanguage = "nativeSystem.translationTargetLanguage"
        static let speechVoiceIdentifier = "nativeSystem.speechVoiceIdentifier"
        static let speechRate = "nativeSystem.speechRate"
    }

    @Published private(set) var spotlightIndexing: Bool?
    @Published private(set) var appLock: Bool?
    @Published private(set) var translationTargetLanguageIdentifier: String?
    @Published private(set) var speechVoiceIdentifier: String?
    @Published private(set) var speechRate: Float?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        spotlightIndexing = defaults.object(forKey: Key.spotlightIndexing) as? Bool
        appLock = defaults.object(forKey: Key.appLock) as? Bool
        translationTargetLanguageIdentifier = defaults.string(forKey: Key.translationTargetLanguage)?.nonBlank
        speechVoiceIdentifier = defaults.string(forKey: Key.speechVoiceIdentifier)?.nonBlank
        if let number = defaults.object(forKey: Key.speechRate) as? NSNumber {
            let value = number.floatValue
            speechRate = Self.validSpeechRate(value) ? value : nil
        } else {
            speechRate = nil
        }
    }

    func setSpotlightIndexing(_ enabled: Bool) {
        spotlightIndexing = enabled
        defaults.set(enabled, forKey: Key.spotlightIndexing)
    }

    func setAppLock(_ enabled: Bool) {
        appLock = enabled
        defaults.set(enabled, forKey: Key.appLock)
    }

    func setTranslationTargetLanguageIdentifier(_ identifier: String?) {
        let value = identifier?.nonBlank
        translationTargetLanguageIdentifier = value
        defaults.set(value, forKey: Key.translationTargetLanguage)
    }

    func setSpeechVoiceIdentifier(_ identifier: String?) {
        let value = identifier?.nonBlank
        speechVoiceIdentifier = value
        defaults.set(value, forKey: Key.speechVoiceIdentifier)
    }

    func setSpeechRate(_ rate: Float?) {
        let value = rate.flatMap { Self.validSpeechRate($0) ? $0 : nil }
        speechRate = value
        defaults.set(value, forKey: Key.speechRate)
    }

    private static func validSpeechRate(_ rate: Float) -> Bool {
        rate.isFinite && rate >= AVSpeechUtteranceMinimumSpeechRate && rate <= AVSpeechUtteranceMaximumSpeechRate
    }
}

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Opt-in performance diagnostics

struct PerformanceDiagnosticEndpoint: Codable, Equatable, Sendable {
    let host: String
    let pathTemplate: String
    let queryKeys: [String]

    init?(url: URL) {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        self.host = host == "zhihu.com" || host.hasSuffix(".zhihu.com") ? host : "untrusted"
        pathTemplate = Self.template(path: url.path)
        queryKeys = Array(Set(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .compactMap { Self.safeKey($0.name) }
        )).sorted()
    }

    private static func template(path: String) -> String {
        let identifierParents: Set<String> = [
            "answers", "articles", "collections", "comments", "favlists", "members",
            "people", "pins", "questions", "topics", "videos", "zvideos",
        ]
        let safeSegments: Set<String> = [
            "activities", "answers", "api", "articles", "collections", "comments",
            "contents", "favlists", "feed", "followers", "following", "hot-lists",
            "items", "members", "notifications", "people", "pins", "questions",
            "recommend", "search_v3", "topstory", "topics", "total", "v2", "v3",
            "v4", "videos", "zvideos",
        ]
        var previous: String?
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map { raw -> String in
            let segment = String(raw).lowercased()
            defer { previous = segment }
            if let previous, identifierParents.contains(previous) { return ":id" }
            if safeSegments.contains(segment) { return segment }
            return ":id"
        }
        return "/" + segments.joined(separator: "/")
    }

    private static func safeKey(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 64 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }
}

struct PerformanceDiagnosticEvent: Sendable {
    enum Result: String, Codable, Sendable {
        case success
        case failure
        case cancelled
    }

    let wallTimestamp: Date
    let durationMilliseconds: Double
    let category: String
    let operation: String
    let result: Result
    let endpoint: PerformanceDiagnosticEndpoint?
    let httpStatus: Int?
    let responseBytes: Int?
    let itemCount: Int?
    let cacheSource: String?
    let pagingSource: String?
    let refreshSource: String?
    let routeType: String?
    let errorKind: String?

    init(
        wallTimestamp: Date = Date(),
        durationMilliseconds: Double = 0,
        category: String,
        operation: String,
        result: Result,
        endpoint: PerformanceDiagnosticEndpoint? = nil,
        httpStatus: Int? = nil,
        responseBytes: Int? = nil,
        itemCount: Int? = nil,
        cacheSource: String? = nil,
        pagingSource: String? = nil,
        refreshSource: String? = nil,
        routeType: String? = nil,
        errorKind: String? = nil
    ) {
        self.wallTimestamp = wallTimestamp
        self.durationMilliseconds = max(0, durationMilliseconds.isFinite ? durationMilliseconds : 0)
        self.category = category
        self.operation = operation
        self.result = result
        self.endpoint = endpoint
        self.httpStatus = httpStatus
        self.responseBytes = responseBytes
        self.itemCount = itemCount
        self.cacheSource = cacheSource
        self.pagingSource = pagingSource
        self.refreshSource = refreshSource
        self.routeType = routeType
        self.errorKind = errorKind
    }

    static func duration(since uptime: TimeInterval) -> Double {
        max(0, (ProcessInfo.processInfo.systemUptime - uptime) * 1_000)
    }

    static func sanitizedErrorKind(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError { return "url_error_\(urlError.errorCode)" }
        if let apiError = error as? ZhihuAPIError {
            switch apiError {
            case .untrustedURL: return "untrusted_url"
            case .invalidResponse: return "invalid_response"
            case let .httpStatus(status): return "http_status_\(status)"
            case .authenticationRequired: return "authentication_required"
            case .accountUnavailable: return "account_unavailable"
            default: return "api_error"
            }
        }
        if error is DecodingError { return "decoding_error" }
        return "unknown_error"
    }
}

struct PerformanceDiagnosticsClient: Sendable {
    private let recordClosure: @Sendable (PerformanceDiagnosticEvent) -> Void

    init(record: @escaping @Sendable (PerformanceDiagnosticEvent) -> Void) {
        recordClosure = record
    }

    func record(_ event: PerformanceDiagnosticEvent) {
        recordClosure(event)
    }

    static let disabled = Self { _ in }
}

struct PerformanceDiagnosticLogFile: Identifiable, Equatable, Sendable {
    let url: URL
    let modifiedAt: Date
    let byteCount: Int64
    var id: URL { url }
}

struct PerformanceDiagnosticSessionContext: Codable, Sendable {
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let deviceModel: String

    static func current() -> Self {
        let info = Bundle.main.infoDictionary ?? [:]
        return Self(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info["CFBundleVersion"] as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: UIDevice.current.model
        )
    }
}

actor PerformanceDiagnosticLogWriter {
    private struct Line: Codable {
        let wallTimestamp: String
        let monotonicDurationMilliseconds: Double
        let sessionID: String
        let appVersion: String
        let appBuild: String
        let osVersion: String
        let deviceModel: String
        let category: String
        let operation: String
        let result: PerformanceDiagnosticEvent.Result
        let endpoint: PerformanceDiagnosticEndpoint?
        let httpStatus: Int?
        let responseBytes: Int?
        let itemCount: Int?
        let cacheSource: String?
        let pagingSource: String?
        let refreshSource: String?
        let routeType: String?
        let errorKind: String?
    }

    private let directory: URL
    private let context: PerformanceDiagnosticSessionContext
    private let maximumSessionBytes: Int64
    private let maximumSessionCount: Int
    private let encoder = JSONEncoder()
    private let timestampFormatter: ISO8601DateFormatter
    private var sessionID: String?
    private var activeURL: URL?
    private var handle: FileHandle?
    private var writtenBytes: Int64 = 0

    init(
        directory: URL,
        context: PerformanceDiagnosticSessionContext = .current(),
        maximumSessionBytes: Int64 = 15 * 1_024 * 1_024,
        maximumSessionCount: Int = 5
    ) {
        self.directory = directory
        self.context = context
        self.maximumSessionBytes = max(1_024, maximumSessionBytes)
        self.maximumSessionCount = max(1, maximumSessionCount)
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = timestampFormatter
    }

    func startSession() {
        guard handle == nil else { return }
        openSession(reason: "start")
    }

    private func openSession(reason: String) {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let id = UUID().uuidString.lowercased()
        let url = directory.appendingPathComponent("performance-\(id).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let fileHandle = try? FileHandle(forWritingTo: url)
        else { return }
        sessionID = id
        activeURL = url
        handle = fileHandle
        writtenBytes = 0
        writeWithoutRollover(.init(category: "session", operation: reason, result: .success))
        pruneOldSessions()
    }

    func finalizeSession() {
        guard handle != nil else { return }
        write(.init(category: "session", operation: "finalize", result: .success))
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        activeURL = nil
        sessionID = nil
        writtenBytes = 0
        pruneOldSessions()
    }

    func record(_ event: PerformanceDiagnosticEvent) {
        guard handle != nil else { return }
        write(event)
    }

    func logs() -> [PerformanceDiagnosticLogFile] {
        try? handle?.synchronize()
        return logFiles()
    }

    func prepareForSharing(_ url: URL) -> URL? {
        guard isManagedLog(url) else { return nil }
        if activeURL == url { try? handle?.synchronize() }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func delete(_ url: URL) {
        guard isManagedLog(url) else { return }
        if activeURL == url { finalizeSession() }
        try? FileManager.default.removeItem(at: url)
    }

    func deleteAll() {
        finalizeSession()
        for log in logFiles() {
            try? FileManager.default.removeItem(at: log.url)
        }
    }

    private func write(_ event: PerformanceDiagnosticEvent) {
        guard handle != nil, sessionID != nil else { return }
        guard let data = encodedLine(event) else { return }
        if writtenBytes + Int64(data.count) > maximumSessionBytes {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
            activeURL = nil
            sessionID = nil
            writtenBytes = 0
            openSession(reason: "rollover")
        }
        writeWithoutRollover(event)
    }

    private func writeWithoutRollover(_ event: PerformanceDiagnosticEvent) {
        guard let handle, let data = encodedLine(event) else { return }
        // A diagnostic line is intentionally bounded and normally far below this limit. If a
        // future schema grows beyond the cap, drop only that line rather than recurse forever.
        guard writtenBytes + Int64(data.count) <= maximumSessionBytes else { return }
        do {
            try handle.write(contentsOf: data)
            writtenBytes += Int64(data.count)
        } catch {
            try? handle.close()
            self.handle = nil
            activeURL = nil
            sessionID = nil
            writtenBytes = 0
        }
    }

    private func encodedLine(_ event: PerformanceDiagnosticEvent) -> Data? {
        guard let sessionID else { return nil }
        let line = Line(
            wallTimestamp: timestampFormatter.string(from: event.wallTimestamp),
            monotonicDurationMilliseconds: event.durationMilliseconds,
            sessionID: sessionID,
            appVersion: context.appVersion,
            appBuild: context.appBuild,
            osVersion: context.osVersion,
            deviceModel: context.deviceModel,
            category: event.category,
            operation: event.operation,
            result: event.result,
            endpoint: event.endpoint,
            httpStatus: event.httpStatus,
            responseBytes: event.responseBytes,
            itemCount: event.itemCount,
            cacheSource: event.cacheSource,
            pagingSource: event.pagingSource,
            refreshSource: event.refreshSource,
            routeType: event.routeType,
            errorKind: event.errorKind
        )
        guard var data = try? encoder.encode(line) else { return nil }
        data.append(0x0A)
        return data
    }

    private func logFiles() -> [PerformanceDiagnosticLogFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard isManagedLog(url),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return nil }
            return PerformanceDiagnosticLogFile(
                url: url,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                byteCount: Int64(values.fileSize ?? 0)
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func pruneOldSessions() {
        for log in logFiles().dropFirst(maximumSessionCount) where log.url != activeURL {
            try? FileManager.default.removeItem(at: log.url)
        }
    }

    private func isManagedLog(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
            && url.pathExtension == "jsonl"
            && url.lastPathComponent.hasPrefix("performance-")
    }
}

/// Synchronously orders commands while keeping file I/O on the writer actor. An off toggle is a
/// barrier: every event enqueued before it is written before finalize, and later events are ignored
/// until a new start command is enqueued.
final class PerformanceDiagnosticsPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: PerformanceDiagnosticLogWriter
    private var tail: Task<Void, Never>?
    private var acceptsEvents = false

    init(writer: PerformanceDiagnosticLogWriter) {
        self.writer = writer
    }

    func record(_ event: PerformanceDiagnosticEvent) {
        lock.withLock {
            guard acceptsEvents else { return }
            _ = enqueueLocked { [writer] in await writer.record(event) }
        }
    }

    @discardableResult
    func startSession() -> Task<Void, Never> {
        lock.withLock {
            let task = enqueueLocked { [writer] in await writer.startSession() }
            acceptsEvents = true
            return task
        }
    }

    @discardableResult
    func finalizeSession() -> Task<Void, Never> {
        lock.withLock {
            acceptsEvents = false
            return enqueueLocked { [writer] in await writer.finalizeSession() }
        }
    }

    func flush() async {
        let pending = lock.withLock { tail }
        await pending?.value
    }

    private func enqueueLocked(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let previous = tail
        let task = Task(priority: .utility) {
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }
}

@MainActor
final class NativePerformanceDiagnosticsController: ObservableObject {
    enum Key {
        static let enabled = "nativePerformanceDiagnostics.enabled"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var logs: [PerformanceDiagnosticLogFile] = []

    let client: PerformanceDiagnosticsClient
    private let defaults: UserDefaults
    private let writer: PerformanceDiagnosticLogWriter
    private let pipeline: PerformanceDiagnosticsPipeline

    init(
        defaults: UserDefaults = .standard,
        directory: URL? = nil
    ) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
        let baseDirectory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("PerformanceDiagnostics", isDirectory: true)
        let writer = PerformanceDiagnosticLogWriter(directory: baseDirectory)
        self.writer = writer
        let pipeline = PerformanceDiagnosticsPipeline(writer: writer)
        self.pipeline = pipeline
        client = PerformanceDiagnosticsClient { event in
            pipeline.record(event)
        }
        if isEnabled { pipeline.startSession() }
        Task {
            await refreshLogs()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        let transition = enabled ? pipeline.startSession() : pipeline.finalizeSession()
        Task {
            await transition.value
            await refreshLogs()
        }
    }

    func refreshLogs() async {
        await pipeline.flush()
        logs = await writer.logs()
    }

    func shareURL(for log: PerformanceDiagnosticLogFile) async -> URL? {
        await pipeline.flush()
        return await writer.prepareForSharing(log.url)
    }

    func delete(_ log: PerformanceDiagnosticLogFile) async {
        await pipeline.flush()
        await writer.delete(log.url)
        if isEnabled { await pipeline.startSession().value }
        await refreshLogs()
    }

    func deleteAll() async {
        await pipeline.flush()
        await writer.deleteAll()
        if isEnabled { await pipeline.startSession().value }
        await refreshLogs()
    }
}
