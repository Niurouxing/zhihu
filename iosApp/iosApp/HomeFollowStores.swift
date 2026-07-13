import Foundation

@MainActor
final class HomeFeedNativeStore: ObservableObject {
    @Published private(set) var items: [FeedItemDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let repository: HomeFeedRepository
    private var nextURL: URL?
    private var isEnd = false
    private var hasLoaded = false
    private var failedOperation: FailedOperation?
    private var generation: UInt64 = 0

    init(repository: HomeFeedRepository) {
        self.repository = repository
    }

    var canLoadMore: Bool { hasLoaded && !isEnd && nextURL != nil && !isLoading }
    var hasNextPage: Bool { hasLoaded && !isEnd && nextURL != nil }
    var nextPageLoadID: String? { nextURL?.absoluteString }

    func loadInitialIfNeeded() async {
        guard !hasLoaded else { return }
        await replacePage(refreshing: false)
    }

    func refresh() async {
        await replacePage(refreshing: true)
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

    private let repository: FollowRepository
    private var recommendationGeneration: UInt64 = 0
    private var momentsGeneration: UInt64 = 0
    private var loadedRecentUsers = false

    init(repository: FollowRepository) {
        self.repository = repository
    }

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

    func refresh(section: FollowSection) async {
        await replace(section: section)
        if section == .recommendations { await reloadRecentUsers() }
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

    private func replace(section: FollowSection) async {
        guard !(section == .recommendations ? recommendations.isLoading : moments.isLoading) else { return }
        let generation = advanceGeneration(section)
        update(section) { page in
            page.isLoading = true
            page.errorMessage = nil
        }
        do {
            let result = try await repository.fetchPage(section: section, after: nil)
            guard generation == currentGeneration(section) else { return }
            update(section) { page in
                page.items = result.items
                page.nextURL = result.nextURL
                page.isEnd = result.isEnd
                page.hasLoaded = true
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
