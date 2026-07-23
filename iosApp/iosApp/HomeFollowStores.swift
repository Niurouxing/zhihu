import Foundation

struct FeedChannelRefreshMetadata: Codable, Equatable {
    var lastSuccessfulRefreshAt: Date?
    var lastViewedAt: Date?

    static let empty = FeedChannelRefreshMetadata(
        lastSuccessfulRefreshAt: nil,
        lastViewedAt: nil
    )
}

enum FeedRefreshChannelID: String, CaseIterable {
    case recommendations
    case following
    case hot
    case daily
}

struct FeedChannelRefreshPolicy: Equatable {
    static let oneHour = FeedChannelRefreshPolicy(idleThreshold: 60 * 60)

    let idleThreshold: TimeInterval

    func needsRefreshAfterIdle(
        metadata: FeedChannelRefreshMetadata,
        now: Date
    ) -> Bool {
        guard let lastViewedAt = metadata.lastViewedAt else { return false }
        if let lastSuccessfulRefreshAt = metadata.lastSuccessfulRefreshAt,
           lastSuccessfulRefreshAt >= lastViewedAt {
            return false
        }
        return now.timeIntervalSince(lastViewedAt) >= idleThreshold
    }
}

protocol FeedChannelRefreshMetadataPersisting {
    func load(for channel: FeedRefreshChannelID) -> FeedChannelRefreshMetadata
    func save(_ metadata: FeedChannelRefreshMetadata, for channel: FeedRefreshChannelID)
}

struct UserDefaultsFeedChannelRefreshMetadataPersistence: FeedChannelRefreshMetadataPersisting {
    static let keyPrefix = "feedChannelRefreshMetadata.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(for channel: FeedRefreshChannelID) -> FeedChannelRefreshMetadata {
        guard let data = defaults.data(forKey: key(for: channel)),
              let metadata = try? JSONDecoder().decode(FeedChannelRefreshMetadata.self, from: data)
        else { return .empty }
        return metadata
    }

    func save(_ metadata: FeedChannelRefreshMetadata, for channel: FeedRefreshChannelID) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        defaults.set(data, forKey: key(for: channel))
    }

    private func key(for channel: FeedRefreshChannelID) -> String {
        "\(Self.keyPrefix).\(channel.rawValue)"
    }
}

struct FeedChannelRefreshTracker {
    let channel: FeedRefreshChannelID
    let persistence: FeedChannelRefreshMetadataPersisting
    let policy: FeedChannelRefreshPolicy
    let now: () -> Date

    func load() -> FeedChannelRefreshMetadata {
        persistence.load(for: channel)
    }

    func recordingSuccessfulRefresh(
        in metadata: FeedChannelRefreshMetadata
    ) -> FeedChannelRefreshMetadata {
        var updated = metadata
        updated.lastSuccessfulRefreshAt = now()
        persistence.save(updated, for: channel)
        return updated
    }

    func recordingLastViewed(
        in metadata: FeedChannelRefreshMetadata,
        at date: Date? = nil
    ) -> FeedChannelRefreshMetadata {
        var updated = metadata
        updated.lastViewedAt = date ?? now()
        persistence.save(updated, for: channel)
        return updated
    }

    func needsRefreshAfterIdle(
        metadata: FeedChannelRefreshMetadata,
        at date: Date? = nil
    ) -> Bool {
        policy.needsRefreshAfterIdle(metadata: metadata, now: date ?? now())
    }
}

@MainActor
final class HomeFeedNativeStore: ObservableObject {
    @Published private(set) var items: [FeedItemDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var refreshMetadata: FeedChannelRefreshMetadata

    private let repository: HomeFeedRepository
    private let refreshTracker: FeedChannelRefreshTracker
    private var nextURL: URL?
    private var isEnd = false
    private var hasLoaded = false
    private var failedOperation: FailedOperation?
    private var generation: UInt64 = 0
    private var refreshRequestID: UInt64 = 0

    init(
        repository: HomeFeedRepository,
        refreshMetadataPersistence: FeedChannelRefreshMetadataPersisting = UserDefaultsFeedChannelRefreshMetadataPersistence(),
        refreshPolicy: FeedChannelRefreshPolicy = .oneHour,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        let refreshTracker = FeedChannelRefreshTracker(
            channel: .recommendations,
            persistence: refreshMetadataPersistence,
            policy: refreshPolicy,
            now: now
        )
        self.refreshTracker = refreshTracker
        refreshMetadata = refreshTracker.load()
    }

    var canLoadMore: Bool { hasLoaded && !isEnd && nextURL != nil && !isLoading }
    var hasNextPage: Bool { hasLoaded && !isEnd && nextURL != nil }
    var nextPageLoadID: String? { nextURL?.absoluteString }

    func loadInitialIfNeeded() async {
        guard !hasLoaded else { return }
        await replacePage(refreshing: false)
    }

    func refresh() async {
        if isRefreshing {
            await waitForActiveRefresh()
            return
        }

        refreshRequestID &+= 1
        let requestID = refreshRequestID
        guard await waitUntilRefreshCanStart(requestID: requestID) else { return }
        await replacePage(refreshing: true)
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

    func loadMore() async {
        guard canLoadMore, let requestedURL = nextURL else { return }
        let currentGeneration = generation
        isLoading = true
        errorMessage = nil
        do {
            let page = try await repository.fetchPage(after: requestedURL)
            guard currentGeneration == generation else { return }
            appendUnique(page.items)
            nextURL = page.nextURL
            isEnd = page.isEnd
            failedOperation = nil
        } catch {
            guard currentGeneration == generation else { return }
            if error.isNativeRequestCancellation {
                isLoading = false
                return
            }
            errorMessage = error.localizedDescription
            failedOperation = .nextPage
        }
        if currentGeneration == generation { isLoading = false }
    }

    func retry() async {
        if failedOperation == .nextPage {
            await loadMore()
        } else {
            await replacePage(refreshing: !items.isEmpty)
        }
    }

    func opened(_ item: FeedItemDTO) {
        Task { await repository.reportOpened(item) }
    }

    private func replacePage(refreshing: Bool) async {
        guard !isLoading else { return }
        generation &+= 1
        let currentGeneration = generation
        isLoading = true
        isRefreshing = refreshing
        errorMessage = nil
        do {
            let page = try await repository.fetchPage(after: nil)
            guard currentGeneration == generation else { return }
            items = page.items
            nextURL = page.nextURL
            isEnd = page.isEnd
            hasLoaded = true
            failedOperation = nil
            refreshMetadata = refreshTracker.recordingSuccessfulRefresh(in: refreshMetadata)
        } catch {
            guard currentGeneration == generation else { return }
            if error.isNativeRequestCancellation {
                isLoading = false
                isRefreshing = false
                return
            }
            errorMessage = error.localizedDescription
            failedOperation = .initial
        }
        if currentGeneration == generation {
            isLoading = false
            isRefreshing = false
        }
    }

    private func waitUntilRefreshCanStart(requestID: UInt64) async -> Bool {
        while isLoading {
            guard requestID == refreshRequestID else { return false }
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return false
            }
        }
        return !Task.isCancelled && requestID == refreshRequestID
    }

    private func waitForActiveRefresh() async {
        while isRefreshing {
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return
            }
        }
    }

    private func appendUnique(_ incoming: [FeedItemDTO]) {
        var known = Set(items.map(\.id))
        items.append(contentsOf: incoming.filter { known.insert($0.id).inserted })
    }

    private enum FailedOperation {
        case initial
        case nextPage
    }
}

@MainActor
final class FollowNativeStore: ObservableObject {
    @Published var selectedSection: FollowSection = .recommendations
    @Published private(set) var recommendations = FollowPageState()
    @Published private(set) var moments = FollowPageState()
    @Published private(set) var recentUsers: [FollowingUserDTO] = []
    @Published private(set) var recentUsersErrorMessage: String?
    @Published private(set) var refreshMetadata: FeedChannelRefreshMetadata

    private let repository: FollowRepository
    private let refreshTracker: FeedChannelRefreshTracker
    private var recommendationGeneration: UInt64 = 0
    private var momentsGeneration: UInt64 = 0
    private var loadedRecentUsers = false

    init(
        repository: FollowRepository,
        refreshMetadataPersistence: FeedChannelRefreshMetadataPersisting = UserDefaultsFeedChannelRefreshMetadataPersistence(),
        refreshPolicy: FeedChannelRefreshPolicy = .oneHour,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        let refreshTracker = FeedChannelRefreshTracker(
            channel: .following,
            persistence: refreshMetadataPersistence,
            policy: refreshPolicy,
            now: now
        )
        self.refreshTracker = refreshTracker
        refreshMetadata = refreshTracker.load()
    }

    var isLoading: Bool { recommendations.isLoading || moments.isLoading }
    var isRefreshing: Bool {
        let page = selectedSection == .recommendations ? recommendations : moments
        return page.isLoading && page.hasLoaded
    }
    var isMomentsLoading: Bool { moments.isLoading }
    var isMomentsRefreshing: Bool { moments.isLoading && moments.hasLoaded }

    func loadInitialIfNeeded() async {
        async let page: Void = loadInitial(section: selectedSection)
        async let users: Void = loadRecentUsersIfNeeded()
        _ = await (page, users)
    }

    func select(_ section: FollowSection) {
        selectedSection = section
    }

    func loadIfNeeded(section: FollowSection) async {
        await loadInitial(section: section)
    }

    func loadMomentsIfNeeded() async {
        async let page: Void = loadInitial(section: .moments)
        async let users: Void = loadRecentUsersIfNeeded()
        _ = await (page, users)
    }

    func refresh(section: FollowSection) async {
        let didRefresh = await replace(section: section)
        if didRefresh, section == .recommendations { await reloadRecentUsers() }
    }

    func refresh() async {
        await refresh(section: selectedSection)
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

    func retry(section: FollowSection) async {
        let page = section == .recommendations ? recommendations : moments
        if page.items.isEmpty {
            await replace(section: section)
        } else {
            await loadMore(section: section)
        }
    }

    func reloadRecentUsers() async {
        do {
            recentUsers = try await repository.fetchRecentUsers()
            loadedRecentUsers = true
            recentUsersErrorMessage = nil
        } catch {
            if error.isNativeRequestCancellation { return }
            loadedRecentUsers = true
            recentUsersErrorMessage = error.localizedDescription
        }
    }

    private func loadRecentUsersIfNeeded() async {
        guard !loadedRecentUsers else { return }
        await reloadRecentUsers()
    }

    private func loadInitial(section: FollowSection) async {
        let page = section == .recommendations ? recommendations : moments
        guard !page.hasLoaded else { return }
        await replace(section: section)
    }

    @discardableResult
    private func replace(section: FollowSection) async -> Bool {
        let page = section == .recommendations ? recommendations : moments
        guard !page.isLoading else { return false }
        let generation = advanceGeneration(section)
        update(section) { page in
            page.isLoading = true
            page.errorMessage = nil
        }
        do {
            let result = try await repository.fetchPage(section: section, after: nil)
            guard generation == currentGeneration(section) else { return false }
            update(section) { page in
                page.items = result.items
                page.nextURL = result.nextURL
                page.isEnd = result.isEnd
                page.hasLoaded = true
                page.isLoading = false
            }
            refreshMetadata = refreshTracker.recordingSuccessfulRefresh(in: refreshMetadata)
            return true
        } catch {
            guard generation == currentGeneration(section) else { return false }
            if error.isNativeRequestCancellation {
                update(section) { $0.isLoading = false }
                return false
            }
            update(section) { page in
                page.isLoading = false
                page.errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func loadMore(section: FollowSection) async {
        let current = section == .recommendations ? recommendations : moments
        guard current.canLoadMore, let nextURL = current.nextURL else { return }
        let generation = currentGeneration(section)
        update(section) { page in
            page.isLoading = true
            page.errorMessage = nil
        }
        do {
            let result = try await repository.fetchPage(section: section, after: nextURL)
            guard generation == currentGeneration(section) else { return }
            update(section) { page in
                var known = Set(page.items.map(\.id))
                page.items.append(contentsOf: result.items.filter { known.insert($0.id).inserted })
                page.nextURL = result.nextURL
                page.isEnd = result.isEnd
                page.isLoading = false
            }
        } catch {
            guard generation == currentGeneration(section) else { return }
            if error.isNativeRequestCancellation {
                update(section) { $0.isLoading = false }
                return
            }
            update(section) { page in
                page.isLoading = false
                page.errorMessage = error.localizedDescription
            }
        }
    }

    private func update(_ section: FollowSection, mutation: (inout FollowPageState) -> Void) {
        switch section {
        case .recommendations: mutation(&recommendations)
        case .moments: mutation(&moments)
        }
    }

    private func advanceGeneration(_ section: FollowSection) -> UInt64 {
        switch section {
        case .recommendations:
            recommendationGeneration &+= 1
            return recommendationGeneration
        case .moments:
            momentsGeneration &+= 1
            return momentsGeneration
        }
    }

    private func currentGeneration(_ section: FollowSection) -> UInt64 {
        section == .recommendations ? recommendationGeneration : momentsGeneration
    }
}
