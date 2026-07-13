import Foundation
import XCTest
@testable import iosApp

@MainActor
final class HotSearchStoreTests: XCTestCase {
    func testHotNextFailureKeepsItemsAndRetryAppendsWithoutDuplicates() async {
        let first = item(id: 1)
        let second = item(id: 2)
        let next = URL(string: "https://www.zhihu.com/api/v3/hot?page=2")!
        let repository = HotRepositoryStub(results: [
            .success(FeedPageDTO(items: [first], nextURL: next, isEnd: false)),
            .failure(StoreTestError.network),
            .success(FeedPageDTO(items: [first, second], nextURL: nil, isEnd: true)),
        ])
        let store = HotFeedStore(repository: repository)

        await store.loadInitialIfNeeded()
        await store.loadNextPage()
        XCTAssertEqual(store.items, [first])
        XCTAssertEqual(store.errorMessage, "网络失败")

        await store.retry()
        XCTAssertEqual(store.items, [first, second])
        XCTAssertNil(store.errorMessage)
    }

    func testSearchHistoryPreservesExistingPayloadThenDeduplicatesAndCapsOnSubmit() async {
        let suite = "HotSearchStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = UserDefaultsSearchHistoryPersistence(defaults: defaults)
        persistence.save((1...20).map { "历史 \($0)" })
        let repository = SearchRepositoryStub(page: .success(FeedPageDTO(items: [], nextURL: nil, isEnd: true)))
        let store = SearchStore(
            route: SearchRouteDTO(),
            repository: repository,
            historyPersistence: persistence,
            defaults: defaults
        )

        await store.submitQuery("历史 5")

        XCTAssertEqual(store.history.count, 20)
        XCTAssertEqual(store.history.first, "历史 5")
        XCTAssertEqual(store.history.filter { $0 == "历史 5" }.count, 1)
        XCTAssertEqual(persistence.load(), store.history)
    }

    func testMemberSearchNeverReadsOrWritesGlobalHistoryAndCarriesRestriction() async {
        let persistence = SearchHistorySpy(initial: ["全局历史"])
        let repository = SearchRepositoryStub(page: .success(FeedPageDTO(items: [], nextURL: nil, isEnd: true)))
        let store = SearchStore(
            route: SearchRouteDTO(
                restrictedMemberHashID: "member-hash",
                restrictedMemberName: "作者"
            ),
            repository: repository,
            historyPersistence: persistence,
            defaults: .standard
        )

        await store.submitQuery("用户创作")

        XCTAssertFalse(store.showsHistory)
        XCTAssertFalse(store.showsHotSearch)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(persistence.saveCount, 0)
        let criteria = await repository.lastCriteria()
        XCTAssertEqual(criteria?.restrictedMemberHashID, "member-hash")
    }

    func testSearchFilterRefreshUsesAllTypedValuesAndKeepsHistoryUnchanged() async {
        let persistence = SearchHistorySpy(initial: [])
        let repository = SearchRepositoryStub(page: .success(FeedPageDTO(items: [], nextURL: nil, isEnd: true)))
        let store = SearchStore(
            route: SearchRouteDTO(query: "搜索"),
            repository: repository,
            historyPersistence: persistence,
            defaults: .standard
        )

        await store.updateSort(.latest)
        await store.updateContentType(.article)
        await store.updateTimeRange(.month)

        let criteria = await repository.lastCriteria()
        XCTAssertEqual(criteria?.sort, .latest)
        XCTAssertEqual(criteria?.contentType, .article)
        XCTAssertEqual(criteria?.timeRange, .month)
        XCTAssertEqual(persistence.saveCount, 0)
    }

    func testClearHistoryPersistsEmptyJSONContract() {
        let persistence = SearchHistorySpy(initial: ["旧搜索"])
        let store = SearchStore(
            route: SearchRouteDTO(),
            repository: SearchRepositoryStub(page: .success(FeedPageDTO(items: [], nextURL: nil, isEnd: true))),
            historyPersistence: persistence,
            defaults: .standard
        )

        store.clearHistory()

        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(persistence.saved ?? ["unexpected"], [])
    }

    func testSearchVisibilityUpdatesWhileStoreRemainsAlive() async {
        let suite = "HotSearchStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: NativeShellPreferences.Key.showSearchHistory)
        defaults.set(false, forKey: NativeShellPreferences.Key.showSearchHotSearch)
        let store = SearchStore(
            route: SearchRouteDTO(),
            repository: SearchRepositoryStub(page: .success(.init(items: [], nextURL: nil, isEnd: true))),
            defaults: defaults
        )

        await store.updateSuggestionVisibility(.init(showsHotSearch: true, showsHistory: true))

        XCTAssertTrue(store.showsHistory)
        XCTAssertTrue(store.showsHotSearch)
    }

    func testHotAndSearchTreatURLCancellationAsSilent() async {
        let hot = HotFeedStore(repository: HotRepositoryStub(results: [.failure(URLError(.cancelled))]))
        await hot.loadInitialIfNeeded()
        XCTAssertNil(hot.errorMessage)

        let search = SearchStore(
            route: SearchRouteDTO(query: "查询"),
            repository: SearchRepositoryStub(page: .failure(URLError(.cancelled)))
        )
        await search.loadInitialIfNeeded()
        XCTAssertNil(search.resultErrorMessage)
    }

    private func item(id: Int64) -> FeedItemDTO {
        FeedItemDTO(
            id: FeedItemID(kind: .article, contentID: String(id)),
            kind: .article,
            title: "文章 \(id)",
            summary: nil,
            details: "文章",
            sourceLabel: nil,
            author: nil,
            thumbnailURL: nil,
            route: .article(articleID: id, title: "文章 \(id)")
        )
    }
}

private enum StoreTestError: LocalizedError {
    case network
    var errorDescription: String? { "网络失败" }
}

private actor HotRepositoryStub: HotFeedRepository {
    private var results: [Result<FeedPageDTO, Error>]

    init(results: [Result<FeedPageDTO, Error>]) { self.results = results }

    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO {
        guard !results.isEmpty else { throw StoreTestError.network }
        return try results.removeFirst().get()
    }
}

private actor SearchRepositoryStub: SearchRepository {
    private let page: Result<FeedPageDTO, Error>
    private var criteria: [SearchCriteria] = []

    init(page: Result<FeedPageDTO, Error>) { self.page = page }

    func fetchSuggestions() async throws -> [SearchSuggestionDTO] { [] }

    func fetchPage(criteria: SearchCriteria, after nextURL: URL?) async throws -> FeedPageDTO {
        self.criteria.append(criteria)
        return try page.get()
    }

    func lastCriteria() -> SearchCriteria? { criteria.last }
}

private final class SearchHistorySpy: SearchHistoryPersistence {
    private let initial: [String]
    private(set) var saved: [String]?
    private(set) var saveCount = 0

    init(initial: [String]) { self.initial = initial }

    func load() -> [String] { initial }

    func save(_ history: [String]) {
        saved = history
        saveCount += 1
    }
}
