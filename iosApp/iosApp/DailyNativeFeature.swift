import Foundation
import SwiftUI

struct DailyStoryDTO: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let sourceURL: URL
    let hint: String
    let imageURL: URL?
}

struct DailySectionDTO: Identifiable, Hashable, Sendable {
    let date: String
    let stories: [DailyStoryDTO]
    var id: String { date }
}

enum DailyStoryDestination: Hashable, Sendable {
    case feed(FeedItemRoute)
    case external(URL)
}

enum DailyStoryResolutionFailureReason: Hashable, Sendable {
    case detailUnavailable
    case missingBody
    case missingOrigin
}

struct DailyStoryResolutionFailure: Identifiable, Hashable, Sendable {
    let storyID: Int64
    let sourceURL: URL
    let reason: DailyStoryResolutionFailureReason

    var id: Int64 { storyID }

    var message: String {
        switch reason {
        case .detailUnavailable:
            return "暂时无法读取日报详情，可以尝试在浏览器中打开。"
        case .missingBody:
            return "日报详情没有可解析的正文，可以尝试在浏览器中打开。"
        case .missingOrigin:
            return "由于知乎日报内容异常，无法找到原文地址。"
        }
    }
}

enum DailyStoryResolution: Hashable, Sendable {
    case destination(DailyStoryDestination)
    case failure(DailyStoryResolutionFailure)
}

protocol DailyRepository: Sendable {
    func fetchLatest() async throws -> DailySectionDTO
    func fetchBefore(_ date: String) async throws -> DailySectionDTO
    func resolveDestination(for story: DailyStoryDTO) async -> DailyStoryResolution
}

actor URLSessionDailyRepository: DailyRepository {
    private static let primaryBase = "https://news-at.zhihu.com/api/4/stories"
    private static let fallbackBase = "https://daily.zhihu.com/api/4/stories"
    private let client: ZhihuAPIClient

    init(client: ZhihuAPIClient) {
        self.client = client
    }

    func fetchLatest() async throws -> DailySectionDTO {
        try await fetch(path: "/latest")
    }

    func fetchBefore(_ date: String) async throws -> DailySectionDTO {
        guard date.range(of: #"^\d{8}$"#, options: .regularExpression) != nil else {
            throw ZhihuAPIError.malformedPayload
        }
        return try await fetch(path: "/before/\(date)")
    }

    func resolveDestination(for story: DailyStoryDTO) async -> DailyStoryResolution {
        guard let detailURL = URL(string: "https://daily.zhihu.com/api/7/story/\(story.id)") else {
            return .failure(.init(
                storyID: story.id,
                sourceURL: story.sourceURL,
                reason: .detailUnavailable
            ))
        }
        let data: Data
        do {
            data = try await client.data(for: detailURL, authentication: .guest)
        } catch {
            return .failure(.init(
                storyID: story.id,
                sourceURL: story.sourceURL,
                reason: .detailUnavailable
            ))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["body"] as? String,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failure(.init(
                storyID: story.id,
                sourceURL: story.sourceURL,
                reason: .missingBody
            ))
        }
        guard let originURL = DailyHTMLOriginParser.originURL(in: body) else {
            return .failure(.init(
                storyID: story.id,
                sourceURL: story.sourceURL,
                reason: .missingOrigin
            ))
        }
        return .destination(DailyRouteResolver.destination(url: originURL, fallbackTitle: story.title))
    }

    private func fetch(path: String) async throws -> DailySectionDTO {
        let primary = URL(string: Self.primaryBase + path)!
        do {
            let data = try await client.data(for: primary, authentication: .guest)
            return try Self.decode(data)
        } catch let error as URLError where Self.isHostResolutionFailure(error) {
            let fallback = URL(string: Self.fallbackBase + path)!
            let data = try await client.data(for: fallback, authentication: .guest)
            return try Self.decode(data)
        }
    }

    private static func decode(_ data: Data) throws -> DailySectionDTO {
        guard let response = try? JSONDecoder().decode(DailyAPIResponse.self, from: data) else {
            throw ZhihuAPIError.malformedPayload
        }
        let stories = response.stories.compactMap { story -> DailyStoryDTO? in
            guard let source = secureURL(story.url) else { return nil }
            return DailyStoryDTO(
                id: story.id,
                title: story.title,
                sourceURL: source,
                hint: story.hint,
                imageURL: story.images.first.flatMap(secureDailyMediaURL)
            )
        }
        return DailySectionDTO(date: response.date, stories: stories)
    }

    private static func isHostResolutionFailure(_ error: URLError) -> Bool {
        error.code == .cannotFindHost || error.code == .dnsLookupFailed
    }
}

private struct DailyAPIResponse: Decodable {
    let date: String
    let stories: [DailyAPIStory]
}

private struct DailyAPIStory: Decodable {
    let id: Int64
    let title: String
    let url: String
    let hint: String
    let images: [String]
}

enum DailyHTMLOriginParser {
    static func originURL(in html: String) -> URL? {
        let candidates = [
            #"<a[^>]*class=[\"'][^\"']*originUrl[^\"']*[\"'][^>]*href=[\"']([^\"']+)[\"']"#,
            #"<a[^>]*href=[\"']([^\"']+)[\"'][^>]*class=[\"'][^\"']*originUrl[^\"']*[\"']"#,
            #"<div[^>]*class=[\"'][^\"']*view-more[^\"']*[\"'][^>]*>[\s\S]*?<a[^>]*href=[\"']([^\"']+)[\"']"#,
        ]
        for pattern in candidates {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html),
                  let url = secureURL(String(html[range]).replacingOccurrences(of: "&amp;", with: "&"))
            else { continue }
            return url
        }
        return nil
    }
}

enum DailyRouteResolver {
    static func destination(url: URL, fallbackTitle: String) -> DailyStoryDestination {
        let parts = url.pathComponents.filter { $0 != "/" }
        let host = url.host?.lowercased()
        if (host == "zhihu.com" || host == "www.zhihu.com"),
           parts.count == 2, parts[0] == "zvideo", let id = Int64(parts[1]) {
            return .feed(.video(.init(
                contentID: id,
                contentType: .zvideo,
                title: fallbackTitle,
                webURL: url
            )))
        }
        if let destination = NativeContentDestinationResolver.resolve(url.absoluteString) {
            switch destination {
            case let .article(id, kind):
                switch kind {
                case .answer:
                    let questionID: Int64?
                    if parts.count == 4, parts[0] == "question", parts[2] == "answer" {
                        questionID = Int64(parts[1])
                    } else {
                        questionID = nil
                    }
                    return .feed(.answer(
                        answerID: id,
                        questionID: questionID,
                        questionTitle: fallbackTitle
                    ))
                case .article:
                    return .feed(.article(articleID: id, title: fallbackTitle))
                }
            case let .question(id):
                return .feed(.question(questionID: id, title: fallbackTitle))
            case let .pin(id):
                return .feed(.pin(pinID: id))
            case let .external(externalURL):
                return .external(externalURL)
            case .person, .special, .column, .search:
                break
            }
        }
        return .external(url)
    }
}

@MainActor
final class DailyNativeStore: ObservableObject {
    @Published private(set) var sections: [DailySectionDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var refreshMetadata: FeedChannelRefreshMetadata

    private let repository: DailyRepository
    private let refreshTracker: FeedChannelRefreshTracker
    private var nextDate: String?
    private var hasLoaded = false
    private var generation: UInt64 = 0

    init(
        repository: DailyRepository,
        refreshMetadataPersistence: FeedChannelRefreshMetadataPersisting = UserDefaultsFeedChannelRefreshMetadataPersistence(),
        refreshPolicy: FeedChannelRefreshPolicy = .oneHour,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        let refreshTracker = FeedChannelRefreshTracker(
            channel: .daily,
            persistence: refreshMetadataPersistence,
            policy: refreshPolicy,
            now: now
        )
        self.refreshTracker = refreshTracker
        refreshMetadata = refreshTracker.load()
    }

    var isRefreshing: Bool { isLoading && hasLoaded }
    var nextPageLoadID: String? { nextDate }

    func loadInitialIfNeeded() async {
        guard !hasLoaded else { return }
        await loadLatest()
    }

    func loadLatest() async {
        await replace(recordsSuccessfulRefresh: true) { try await repository.fetchLatest() }
    }

    func refresh() async {
        await loadLatest()
    }

    func recordLastViewed() {
        refreshMetadata = refreshTracker.recordingLastViewed(in: refreshMetadata)
    }

    func recordLastViewed(at date: Date) {
        refreshMetadata = refreshTracker.recordingLastViewed(in: refreshMetadata, at: date)
    }

    func needsRefreshAfterIdle() -> Bool {
        refreshTracker.needsRefreshAfterIdle(metadata: refreshMetadata)
    }

    func needsRefreshAfterIdle(at date: Date) -> Bool {
        refreshTracker.needsRefreshAfterIdle(metadata: refreshMetadata, at: date)
    }

    func accountDidChange() {
        generation &+= 1
        sections = []
        isLoading = false
        isLoadingMore = false
        errorMessage = nil
        nextDate = nil
        hasLoaded = false
        refreshMetadata = refreshTracker.clearing()
    }

    func load(date: Date, calendar: Calendar = .current) async {
        guard let requestDate = calendar.date(byAdding: .day, value: 1, to: date) else { return }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let value = formatter.string(from: requestDate)
        await replace(recordsSuccessfulRefresh: false) { try await repository.fetchBefore(value) }
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, let nextDate else { return }
        let current = generation
        isLoadingMore = true
        do {
            let section = try await repository.fetchBefore(nextDate)
            guard current == generation else { return }
            guard !Task.isCancelled else {
                isLoadingMore = false
                return
            }
            if !section.stories.isEmpty, !sections.contains(where: { $0.id == section.id }) {
                sections.append(section)
            }
            self.nextDate = section.date
        } catch {
            guard current == generation else { return }
            if Task.isCancelled || error.isNativeRequestCancellation {
                isLoadingMore = false
                return
            }
            errorMessage = error.localizedDescription
        }
        if current == generation { isLoadingMore = false }
    }

    func destination(for story: DailyStoryDTO) async -> DailyStoryResolution {
        await repository.resolveDestination(for: story)
    }

    private func replace(
        recordsSuccessfulRefresh: Bool,
        operation: () async throws -> DailySectionDTO
    ) async {
        guard !isLoading, !isLoadingMore else { return }
        generation &+= 1
        let current = generation
        isLoading = true
        errorMessage = nil
        do {
            let section = try await operation()
            guard current == generation else { return }
            guard !Task.isCancelled else {
                isLoading = false
                return
            }
            sections = section.stories.isEmpty ? [] : [section]
            nextDate = section.date
            hasLoaded = true
            if recordsSuccessfulRefresh {
                refreshMetadata = refreshTracker.recordingSuccessfulRefresh(in: refreshMetadata)
            }
        } catch {
            guard current == generation else { return }
            if Task.isCancelled || error.isNativeRequestCancellation {
                isLoading = false
                return
            }
            errorMessage = error.localizedDescription
        }
        if current == generation { isLoading = false }
    }
}

struct DailyNativeView: View {
    @ObservedObject private var store: DailyNativeStore
    @Environment(\.nativeChannelIsActive) private var isActiveChannel
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @State private var navigationTask: Task<Void, Never>?
    @State private var supplementalLoadTask: Task<Void, Never>?
    @State private var resolutionFailure: DailyStoryResolutionFailure?
    @State private var observedScrollToTopRequest: UInt
    @State private var lastHiddenSearchEntryTarget: NativeHomeContentScrollTarget?
    let scrollToTopRequest: UInt
    private let onOpenSearch: (() -> Void)?
    let onOpen: (DailyStoryDestination) -> Void

    init(
        store: DailyNativeStore,
        scrollToTopRequest: UInt,
        onOpenSearch: (() -> Void)? = nil,
        onOpen: @escaping (DailyStoryDestination) -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        _observedScrollToTopRequest = State(initialValue: scrollToTopRequest)
        self.scrollToTopRequest = scrollToTopRequest
        self.onOpenSearch = onOpenSearch
        self.onOpen = onOpen
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Color.clear
                    .frame(height: 0)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .accessibilityHidden(true)
                    .id(NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .daily))

                if let onOpenSearch {
                    NativeHomeGlobalSearchEntry(action: onOpenSearch)
                }

                if store.sections.isEmpty, store.isLoading {
                    HStack { Spacer(); ProgressView("正在加载日报"); Spacer() }
                        .listRowSeparator(.hidden)
                        .id(NativeHomeContentScrollTarget.dailyStatus)
                }
                ForEach(store.sections) { section in
                    Section(formatted(section.date)) {
                        ForEach(section.stories) { story in
                            Button {
                                navigationTask?.cancel()
                                navigationTask = Task {
                                    let resolution = await store.destination(for: story)
                                    guard !Task.isCancelled else { return }
                                    switch resolution {
                                    case let .destination(destination):
                                        onOpen(destination)
                                    case let .failure(failure):
                                        resolutionFailure = failure
                                    }
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(story.title).font(.headline).foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(story.hint).font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    if let imageURL = story.imageURL {
                                        AsyncImage(url: imageURL) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: {
                                            Color.secondary.opacity(0.12)
                                        }
                                        .frame(width: 92, height: 68)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .id(NativeHomeContentScrollTarget.daily(story.id))
                            .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                        }
                    }
                }
                if let error = store.errorMessage {
                    FeedRetryRow(message: error) {
                        supplementalLoadTask?.cancel()
                        supplementalLoadTask = Task { await store.loadLatest() }
                    }
                    .id(NativeHomeContentScrollTarget.dailyStatus)
                } else if !store.sections.isEmpty {
                    let taskID = NativeChannelTaskIdentity(
                        isActive: isActiveChannel,
                        value: store.nextPageLoadID
                    )
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                        .id(NativeHomeContentScrollTarget.dailyStatus)
                        .task(id: taskID) {
                            guard taskID.isActive,
                                  taskID.value == store.nextPageLoadID
                            else { return }
                            await store.loadMore()
                        }
                } else if !store.isLoading {
                    Text("暂无日报内容")
                        .foregroundStyle(.secondary)
                        .id(NativeHomeContentScrollTarget.dailyStatus)
                }
            }
            .listStyle(.plain)
            .nativeHomeFeedListLayout()
            .refreshable {
                guard isActiveChannel else { return }
                let previousSuccessfulRefresh = store.refreshMetadata.lastSuccessfulRefreshAt
                await store.refresh()
                if !Task.isCancelled,
                   NativeRefreshHapticPolicy.shouldEmit(
                    previousSuccessfulRefreshAt: previousSuccessfulRefresh,
                    currentSuccessfulRefreshAt: store.refreshMetadata.lastSuccessfulRefreshAt
                   ) {
                    hapticFeedback(.refreshSucceeded)
                }
            }
            .onAppear {
                observedScrollToTopRequest = scrollToTopRequest
                hideInitialSearchEntryIfNeeded(proxy)
            }
            .onChange(of: scrollToTopRequest) { newRequest in
                let shouldScroll = NativeScrollToTopRequestPolicy.shouldHandleChange(
                    previousRequest: observedScrollToTopRequest,
                    newRequest: newRequest
                )
                observedScrollToTopRequest = newRequest
                if shouldScroll { scrollToTop(proxy, animated: true) }
            }
            .onChange(of: firstContentScrollTarget) { _ in
                hideInitialSearchEntryIfNeeded(proxy)
            }
            .task(id: isActiveChannel) {
                guard isActiveChannel else { return }
                await store.loadInitialIfNeeded()
            }
            .onChange(of: isActiveChannel) { isActive in
                if !isActive {
                    navigationTask?.cancel()
                    supplementalLoadTask?.cancel()
                } else {
                    hideInitialSearchEntryIfNeeded(proxy)
                }
            }
            .onDisappear {
                navigationTask?.cancel()
                supplementalLoadTask?.cancel()
            }
            .alert(
                "无法找到日报原文",
                isPresented: Binding(
                    get: { resolutionFailure != nil },
                    set: { if !$0 { resolutionFailure = nil } }
                ),
                presenting: resolutionFailure
            ) { failure in
                Button("浏览器打开") {
                    resolutionFailure = nil
                    onOpen(.external(failure.sourceURL))
                }
                Button("取消", role: .cancel) {
                    resolutionFailure = nil
                }
            } message: { failure in
                Text(failure.message)
            }
        }
        .accessibilityIdentifier("daily_native")
    }

    private func formatted(_ date: String) -> String {
        guard date.count == 8 else { return date }
        return "\(date.prefix(4)) 年 \(date.dropFirst(4).prefix(2)) 月 \(date.suffix(2)) 日"
    }

    private var firstContentScrollTarget: NativeHomeContentScrollTarget? {
        store.sections
            .lazy
            .compactMap(\.stories.first)
            .first
            .map { .daily($0.id) } ?? .dailyStatus
    }

    private func scrollToTop(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation {
                    if let firstContentScrollTarget {
                        proxy.scrollTo(firstContentScrollTarget, anchor: .top)
                    } else {
                        proxy.scrollTo(
                            NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .daily),
                            anchor: .top
                        )
                    }
                }
            } else if let firstContentScrollTarget {
                proxy.scrollTo(firstContentScrollTarget, anchor: .top)
            } else {
                proxy.scrollTo(
                    NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .daily),
                    anchor: .top
                )
            }
        }
    }

    private func hideInitialSearchEntryIfNeeded(_ proxy: ScrollViewProxy) {
        NativeHomeSearchEntryScrollController.hideIfNeeded(
            in: proxy,
            target: firstContentScrollTarget,
            isActive: isActiveChannel,
            lastHiddenTarget: $lastHiddenSearchEntryTarget
        )
    }
}

private func secureURL(_ value: String) -> URL? {
    guard var components = URLComponents(string: value) else { return nil }
    if components.scheme?.lowercased() == "http" { components.scheme = "https" }
    guard let url = components.url, ZhihuAPIURLPolicy.allows(url) else { return nil }
    return url
}

private func secureDailyMediaURL(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme?.lowercased() == "https" else { return nil }
    return url
}
