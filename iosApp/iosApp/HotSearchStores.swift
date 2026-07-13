import Foundation

@MainActor
final class HotFeedStore: ObservableObject {
    @Published private(set) var items: [FeedItemDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private let repository: HotFeedRepository
    private var nextURL: URL?
    private var isEnd = false
    private var hasLoaded = false
    private var failedOperation: FailedOperation?

    init(repository: HotFeedRepository) {
        self.repository = repository
    }

    var canLoadNextPage: Bool { hasLoaded && !isEnd && nextURL != nil }

    func loadInitialIfNeeded() async {
        guard !hasLoaded else { return }
        await replacePage(isRefresh: false)
    }

    func refresh() async {
        await replacePage(isRefresh: true)
    }

    func loadNextPage() async {
        guard hasLoaded, !isEnd, !isLoading, let nextURL else { return }
        isLoading = true
        errorMessage = nil
        do {
            let page = try await repository.fetchPage(after: nextURL)
            appendUnique(page.items)
            self.nextURL = page.nextURL
            isEnd = page.isEnd
            failedOperation = nil
        } catch {
            if error.isNativeRequestCancellation {
                isLoading = false
                return
            }
            errorMessage = error.localizedDescription
            failedOperation = .next
        }
        isLoading = false
    }

    func retry() async {
        switch failedOperation {
        case .next:
            await loadNextPage()
        case .initial, .none:
            await replacePage(isRefresh: !items.isEmpty)
        }
    }

    private func replacePage(isRefresh: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        isRefreshing = isRefresh
        errorMessage = nil
        do {
            let page = try await repository.fetchPage(after: nil)
            items = page.items
            nextURL = page.nextURL
            isEnd = page.isEnd
            hasLoaded = true
            failedOperation = nil
        } catch {
            if error.isNativeRequestCancellation {
                isLoading = false
                isRefreshing = false
                return
            }
            errorMessage = error.localizedDescription
            failedOperation = .initial
        }
        isLoading = false
        isRefreshing = false
    }

    private func appendUnique(_ incoming: [FeedItemDTO]) {
        var known = Set(items.map(\.id))
        items.append(contentsOf: incoming.filter { known.insert($0.id).inserted })
    }

    private enum FailedOperation {
        case initial
        case next
    }
}

protocol SearchHistoryPersistence {
    func load() -> [String]
    func save(_ history: [String])
}

struct UserDefaultsSearchHistoryPersistence: SearchHistoryPersistence {
    static let key = "searchHistoryQueries"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        guard let payload = defaults.string(forKey: Self.key),
              let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }

    func save(_ history: [String]) {
        guard let data = try? JSONEncoder().encode(history),
              let payload = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(payload, forKey: Self.key)
    }
}

@MainActor
final class SearchStore: ObservableObject {
    @Published var queryText: String
    @Published private(set) var submittedQuery: String
    @Published private(set) var items: [FeedItemDTO] = []
    @Published private(set) var suggestions: [SearchSuggestionDTO] = []
    @Published private(set) var history: [String]
    @Published private(set) var isLoadingResults = false
    @Published private(set) var isRefreshingSuggestions = false
    @Published private(set) var resultErrorMessage: String?
    @Published private(set) var suggestionErrorMessage: String?
    @Published private(set) var sort: SearchSort = .relevance
    @Published private(set) var contentType: SearchContentType = .all
    @Published private(set) var timeRange: SearchTimeRange = .all

    let route: SearchRouteDTO
    @Published private(set) var showsHistory: Bool
    @Published private(set) var showsHotSearch: Bool

    private let repository: SearchRepository
    private let historyPersistence: SearchHistoryPersistence
    private var nextURL: URL?
    private var isEnd = false
    private var hasLoadedInitialState = false
    private var failedResultOperation: FailedResultOperation?
    private var searchGeneration: UInt64 = 0
    private var suggestionGeneration: UInt64 = 0

    init(
        route: SearchRouteDTO,
        repository: SearchRepository,
        historyPersistence: SearchHistoryPersistence = UserDefaultsSearchHistoryPersistence(),
        defaults: UserDefaults = .standard
    ) {
        self.route = route
        self.repository = repository
        self.historyPersistence = historyPersistence
        queryText = route.query
        submittedQuery = route.query
        if route.isMemberRestricted {
            showsHistory = false
            showsHotSearch = false
            history = []
        } else {
            showsHistory = defaults.object(forKey: "showSearchHistory") == nil
                ? true
                : defaults.bool(forKey: "showSearchHistory")
            showsHotSearch = defaults.object(forKey: "showSearchHotSearch") == nil
                ? true
                : defaults.bool(forKey: "showSearchHotSearch")
            history = historyPersistence.load()
        }
    }

    var memberDisplayName: String { route.restrictedMemberName ?? "TA" }

    var canLoadNextPage: Bool { !isEnd && nextURL != nil }

    var criteria: SearchCriteria {
        SearchCriteria(
            query: submittedQuery,
            restrictedMemberHashID: route.restrictedMemberHashID,
            sort: sort,
            contentType: contentType,
            timeRange: timeRange
        )
    }

    func updateSuggestionVisibility(_ preferences: NativeSearchPresentationPreferences) async {
        guard !route.isMemberRestricted else { return }
        let hotChanged = showsHotSearch != preferences.showsHotSearch
        showsHistory = preferences.showsHistory
        showsHotSearch = preferences.showsHotSearch
        guard hotChanged else { return }
        suggestionGeneration &+= 1
        if showsHotSearch {
            await refreshSuggestions()
        } else {
            suggestions = []
            suggestionErrorMessage = nil
            isRefreshingSuggestions = false
        }
    }

    func loadInitialIfNeeded() async {
        guard !hasLoadedInitialState else { return }
        hasLoadedInitialState = true
        if submittedQuery.isEmpty {
            if showsHotSearch { await refreshSuggestions() }
        } else {
            await replaceResults()
        }
    }

    func submitQuery(_ value: String? = nil) async {
        let query = (value ?? queryText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        queryText = query
        submittedQuery = query
        sort = .relevance
        contentType = .all
        timeRange = .all
        if showsHistory {
            history.removeAll { $0 == query }
            history.insert(query, at: 0)
            if history.count > 20 { history.removeSubrange(20...) }
            historyPersistence.save(history)
        }
        await replaceResults()
    }

    func clearQuery() {
        searchGeneration &+= 1
        queryText = ""
        submittedQuery = ""
        items = []
        nextURL = nil
        isEnd = false
        isLoadingResults = false
        resultErrorMessage = nil
        failedResultOperation = nil
    }

    func clearHistory() {
        history = []
        historyPersistence.save([])
    }

    func refreshSuggestions() async {
        guard showsHotSearch, !isRefreshingSuggestions else { return }
        let generation = suggestionGeneration
        isRefreshingSuggestions = true
        suggestionErrorMessage = nil
        do {
            let loaded = try await repository.fetchSuggestions()
            guard generation == suggestionGeneration, showsHotSearch else { return }
            suggestions = loaded
        } catch {
            guard generation == suggestionGeneration, showsHotSearch else { return }
            if error.isNativeRequestCancellation {
                isRefreshingSuggestions = false
                return
            }
            suggestionErrorMessage = error.localizedDescription
        }
        if generation == suggestionGeneration { isRefreshingSuggestions = false }
    }

    func updateSort(_ value: SearchSort) async {
        guard sort != value else { return }
        sort = value
        await replaceResults()
    }

    func updateContentType(_ value: SearchContentType) async {
        guard contentType != value else { return }
        contentType = value
        await replaceResults()
    }

    func updateTimeRange(_ value: SearchTimeRange) async {
        guard timeRange != value else { return }
        timeRange = value
        await replaceResults()
    }

    func refreshResults() async {
        await replaceResults()
    }

    func loadNextPage() async {
        guard !submittedQuery.isEmpty,
              !isLoadingResults,
              !isEnd,
              let nextURL
        else { return }
        let generation = searchGeneration
        let requestedCriteria = criteria
        isLoadingResults = true
        resultErrorMessage = nil
        do {
            let page = try await repository.fetchPage(criteria: requestedCriteria, after: nextURL)
            guard generation == searchGeneration else { return }
            appendUnique(page.items)
            self.nextURL = page.nextURL
            isEnd = page.isEnd
            failedResultOperation = nil
        } catch {
            guard generation == searchGeneration else { return }
            if error.isNativeRequestCancellation {
                isLoadingResults = false
                return
            }
            resultErrorMessage = error.localizedDescription
            failedResultOperation = .next
        }
        if generation == searchGeneration { isLoadingResults = false }
    }

    func retryResults() async {
        switch failedResultOperation {
        case .next:
            await loadNextPage()
        case .initial, .none:
            await replaceResults()
        }
    }

    private func replaceResults() async {
        guard !submittedQuery.isEmpty else { return }
        searchGeneration &+= 1
        let generation = searchGeneration
        let requestedCriteria = criteria
        isLoadingResults = true
        resultErrorMessage = nil
        do {
            let page = try await repository.fetchPage(criteria: requestedCriteria, after: nil)
            guard generation == searchGeneration else { return }
            items = page.items
            nextURL = page.nextURL
            isEnd = page.isEnd
            failedResultOperation = nil
        } catch {
            guard generation == searchGeneration else { return }
            if error.isNativeRequestCancellation {
                isLoadingResults = false
                return
            }
            resultErrorMessage = error.localizedDescription
            failedResultOperation = .initial
        }
        if generation == searchGeneration { isLoadingResults = false }
    }

    private func appendUnique(_ incoming: [FeedItemDTO]) {
        var known = Set(items.map(\.id))
        items.append(contentsOf: incoming.filter { known.insert($0.id).inserted })
    }

    private enum FailedResultOperation {
        case initial
        case next
    }
}
