import Foundation
import XCTest
@testable import iosApp

final class FeedChannelRefreshMetadataTests: XCTestCase {
    func testOneHourPolicyRefreshesAtThresholdSinceLastView() {
        let lastViewed = Date(timeIntervalSince1970: 1_000)
        let metadata = FeedChannelRefreshMetadata(
            lastSuccessfulRefreshAt: nil,
            lastViewedAt: lastViewed
        )

        XCTAssertFalse(FeedChannelRefreshPolicy.oneHour.needsRefreshAfterIdle(
            metadata: metadata,
            now: lastViewed.addingTimeInterval(60 * 60 - 1)
        ))
        XCTAssertTrue(FeedChannelRefreshPolicy.oneHour.needsRefreshAfterIdle(
            metadata: metadata,
            now: lastViewed.addingTimeInterval(60 * 60)
        ))
        XCTAssertFalse(FeedChannelRefreshPolicy.oneHour.needsRefreshAfterIdle(
            metadata: .empty,
            now: lastViewed.addingTimeInterval(60 * 60 + 1)
        ))
        XCTAssertFalse(FeedChannelRefreshPolicy.oneHour.needsRefreshAfterIdle(
            metadata: FeedChannelRefreshMetadata(
                lastSuccessfulRefreshAt: lastViewed.addingTimeInterval(60 * 60 + 1),
                lastViewedAt: lastViewed
            ),
            now: lastViewed.addingTimeInterval(60 * 60 + 2)
        ))
    }

    func testUserDefaultsPersistenceUsesStableIndependentChannelKeys() throws {
        let suite = "FeedChannelRefreshMetadataTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = UserDefaultsFeedChannelRefreshMetadataPersistence(defaults: defaults)
        let recommendations = FeedChannelRefreshMetadata(
            lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 10),
            lastViewedAt: Date(timeIntervalSince1970: 20)
        )
        let hot = FeedChannelRefreshMetadata(
            lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 30),
            lastViewedAt: Date(timeIntervalSince1970: 40)
        )

        persistence.save(recommendations, for: .recommendations)
        persistence.save(hot, for: .hot)

        XCTAssertEqual(persistence.load(for: .recommendations), recommendations)
        XCTAssertEqual(persistence.load(for: .hot), hot)
        XCTAssertEqual(persistence.load(for: .following), .empty)
        XCTAssertEqual(persistence.load(for: .daily), .empty)
        XCTAssertNotNil(defaults.data(
            forKey: "\(UserDefaultsFeedChannelRefreshMetadataPersistence.keyPrefix).recommendations"
        ))
    }
}

final class HomeFollowMapperTests: XCTestCase {
    func testFeedMapperKeepsAuthorSourceThumbnailAndTypedAnswerRoute() throws {
        let data = Data(
            #"{"data":[{"detail_text":"关注的人赞同了","target":{"id":42,"type":"answer","excerpt":"摘要","voteup_count":10,"comment_count":2,"thumbnail":"https://pic.zhimg.com/a.jpg","question":{"id":7,"title":"问题"},"author":{"id":"member","url_token":"writer","name":"作者","headline":"简介","avatar_url":"https://pic.zhimg.com/avatar.jpg"}}}],"paging":{"is_end":false,"next":"http://www.zhihu.com/api/v3/next"}}"#.utf8
        )

        let page = try FeedResponseMapper.page(from: data, policy: .search)

        XCTAssertEqual(page.items.first?.route, .answer(answerID: 42, questionID: 7, questionTitle: "问题"))
        XCTAssertEqual(page.items.first?.author?.displayName, "作者")
        XCTAssertEqual(page.items.first?.sourceLabel, "关注的人赞同了")
        XCTAssertEqual(page.items.first?.thumbnailURL, URL(string: "https://pic.zhimg.com/a.jpg"))
        XCTAssertEqual(page.nextURL, URL(string: "https://www.zhihu.com/api/v3/next"))
    }

    func testFeedMapperIgnoresStringAuthorWithoutDroppingItem() throws {
        let data = Data(
            #"{"data":[{"target":{"id":"81","type":"article","title":"字符串作者文章","excerpt":"摘要","author":"匿名用户"}}],"paging":{"is_end":true,"next":null}}"#.utf8
        )

        let page = try FeedResponseMapper.page(from: data, policy: .search)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.route, .article(articleID: 81, title: "字符串作者文章"))
        XCTAssertNil(page.items.first?.author)
    }

    func testFeedMapperKeepsMixedObjectAndStringAuthorPage() throws {
        let data = Data(
            #"{"data":[{"target":{"id":"81","type":"article","title":"对象作者文章","author":{"id":"member","url_token":"writer","name":"对象作者","headline":"简介"}}},{"target":{"id":"82","type":"article","title":"字符串作者文章","author":"匿名用户"}}],"paging":{"is_end":true,"next":null}}"#.utf8
        )

        let page = try FeedResponseMapper.page(from: data, policy: .search)

        XCTAssertEqual(page.items.map(\.route), [
            .article(articleID: 81, title: "对象作者文章"),
            .article(articleID: 82, title: "字符串作者文章"),
        ])
        XCTAssertEqual(page.items.first?.author?.displayName, "对象作者")
        XCTAssertNil(page.items.last?.author)
    }

    func testFeedMapperRejectsUntrustedPagingURL() throws {
        let data = Data(#"{"data":[],"paging":{"is_end":false,"next":"https://evil.example/steal"}}"#.utf8)
        XCTAssertThrowsError(try FeedResponseMapper.page(from: data, policy: .search))
    }

    func testRecommendationRequestUsesFortyForFirstPageAndContinuation() throws {
        let firstPage = try HomeFollowRequestURL.addingRecommendationFeedParameters(
            to: URL(string: "https://api.zhihu.com/topstory/recommend?limit=20")!
        )
        let continuation = try HomeFollowRequestURL.addingRecommendationFeedParameters(
            to: URL(
                string: "https://api.zhihu.com/topstory/recommend?offset=40&cursor=next-token&limit=20"
            )!
        )
        let firstItems = try XCTUnwrap(
            URLComponents(url: firstPage, resolvingAgainstBaseURL: false)?.queryItems
        )
        let continuationItems = try XCTUnwrap(
            URLComponents(url: continuation, resolvingAgainstBaseURL: false)?.queryItems
        )

        XCTAssertEqual(firstItems.filter { $0.name == "limit" }.map(\.value), ["40"])
        XCTAssertEqual(continuationItems.filter { $0.name == "limit" }.map(\.value), ["40"])
        XCTAssertEqual(continuationItems.first(where: { $0.name == "offset" })?.value, "40")
        XCTAssertEqual(
            continuationItems.first(where: { $0.name == "cursor" })?.value,
            "next-token"
        )
    }

    func testFollowRequestKeepsExistingQueryAndAddsPagingParametersOnce() throws {
        let source = URL(string: "https://api.zhihu.com/moments_v3?feed_type=recommend&limit=10")!
        let first = try HomeFollowRequestURL.addingFeedParameters(to: source)
        let second = try HomeFollowRequestURL.addingFeedParameters(to: first)
        let items = try XCTUnwrap(URLComponents(url: second, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertEqual(items.first(where: { $0.name == "feed_type" })?.value, "recommend")
        XCTAssertEqual(items.filter { $0.name == "include" }.count, 1)
        XCTAssertEqual(items.filter { $0.name == "limit" }.count, 1)
        XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "20")
    }

    func testRecentUserCarriesUnreadAndPersonActivitiesTab() throws {
        let data = Data(
            #"{"data":[{"actor":{"id":"member","url_token":"writer","name":"作者","avatar_url":"https://pic.zhimg.com/a.jpg"},"unread_count":3}]}"#.utf8
        )

        let user = try XCTUnwrap(HomeFollowResponseMapper.followingUsers(from: data).first)

        XCTAssertEqual(user.unreadCount, 3)
        XCTAssertEqual(user.personRoute?.initialTab, .activities)
        XCTAssertEqual(user.personRoute?.lookupKey, .memberID("member"))
    }

}

@MainActor
final class HomeFollowStoreTests: XCTestCase {
    func testHomeRecordsOnlySuccessfulFirstPageAndPersistsLastViewed() async {
        let initialDate = Date(timeIntervalSince1970: 1_000)
        let clock = FeedRefreshTestClock(initialDate)
        let persistence = InMemoryFeedRefreshMetadataPersistence()
        let first = feedItem(1)
        let second = feedItem(2)
        let next = URL(string: "https://www.zhihu.com/api/v3/next")!
        let repository = HomeRepositoryStub(results: [
            .success(FeedPageDTO(items: [first], nextURL: next, isEnd: false)),
            .success(FeedPageDTO(items: [second], nextURL: nil, isEnd: true)),
            .failure(HomeFollowTestError.network),
        ])
        let store = HomeFeedNativeStore(
            repository: repository,
            refreshMetadataPersistence: persistence,
            now: { clock.now }
        )

        await store.loadInitialIfNeeded()
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, initialDate)

        clock.now = initialDate.addingTimeInterval(10)
        await store.loadMore()
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, initialDate)

        clock.now = initialDate.addingTimeInterval(20)
        await store.refresh()
        XCTAssertEqual(store.items, [first, second])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, initialDate)

        let viewedAt = initialDate.addingTimeInterval(30)
        store.recordLastViewed(at: viewedAt)
        XCTAssertEqual(store.refreshMetadata.lastViewedAt, viewedAt)
        XCTAssertFalse(store.needsRefreshAfterIdle(at: viewedAt.addingTimeInterval(60 * 60 - 1)))
        XCTAssertTrue(store.needsRefreshAfterIdle(at: viewedAt.addingTimeInterval(60 * 60)))

        let restored = HomeFeedNativeStore(
            repository: HomeRepositoryStub(results: []),
            refreshMetadataPersistence: persistence
        )
        XCTAssertEqual(restored.refreshMetadata, store.refreshMetadata)
    }

    func testHomeManualRefreshReplacesFirstPageAndRecordsCurrentTime() async {
        let initialDate = Date(timeIntervalSince1970: 3_000)
        let refreshDate = initialDate.addingTimeInterval(120)
        let clock = FeedRefreshTestClock(initialDate)
        let first = feedItem(1)
        let refreshed = feedItem(2)
        let store = HomeFeedNativeStore(
            repository: HomeRepositoryStub(results: [
                .success(FeedPageDTO(items: [first], nextURL: nil, isEnd: true)),
                .success(FeedPageDTO(items: [refreshed], nextURL: nil, isEnd: true)),
            ]),
            refreshMetadataPersistence: InMemoryFeedRefreshMetadataPersistence(),
            now: { clock.now }
        )

        await store.loadInitialIfNeeded()
        clock.now = refreshDate
        await store.refresh()

        XCTAssertEqual(store.items, [refreshed])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, refreshDate)
        XCTAssertFalse(store.isRefreshing)
    }

    func testHomeRefreshQueuedDuringPaginationEventuallyRefreshesFirstPage() async {
        let initial = feedItem(1)
        let paginated = feedItem(2)
        let refreshed = feedItem(3)
        let nextURL = URL(string: "https://www.zhihu.com/api/v3/next")!
        let repository = HomePaginationRefreshRepositoryStub(
            initial: FeedPageDTO(items: [initial], nextURL: nextURL, isEnd: false),
            paginated: FeedPageDTO(items: [paginated], nextURL: nil, isEnd: true),
            refreshed: FeedPageDTO(items: [refreshed], nextURL: nil, isEnd: true)
        )
        let store = HomeFeedNativeStore(repository: repository)
        await store.loadInitialIfNeeded()

        let pagination = Task { await store.loadMore() }
        await repository.waitUntilPaginationStarts()
        let refresh = Task { await store.refresh() }
        for _ in 0..<5 { await Task.yield() }

        let requestsWhilePaginating = await repository.requestedURLs()
        XCTAssertEqual(requestsWhilePaginating, [nil, nextURL])
        XCTAssertEqual(store.items, [initial])

        await repository.resumePagination()
        await pagination.value
        await refresh.value

        let completedRequests = await repository.requestedURLs()
        XCTAssertEqual(completedRequests, [nil, nextURL, nil])
        XCTAssertEqual(store.items, [refreshed])
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.isRefreshing)
    }

    func testFollowFailedRefreshDoesNotReplaceSuccessfulRefreshTime() async {
        let initialDate = Date(timeIntervalSince1970: 2_000)
        let clock = FeedRefreshTestClock(initialDate)
        let persistence = InMemoryFeedRefreshMetadataPersistence()
        let recommend = feedItem(1)
        let repository = FollowRepositoryStub(pages: [
            .recommendations: [
                .success(FeedPageDTO(items: [recommend], nextURL: nil, isEnd: true)),
                .failure(HomeFollowTestError.network),
            ],
        ])
        let store = FollowNativeStore(
            repository: repository,
            refreshMetadataPersistence: persistence,
            now: { clock.now }
        )

        await store.loadInitialIfNeeded()
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, initialDate)

        clock.now = initialDate.addingTimeInterval(100)
        await store.refresh(section: .recommendations)

        XCTAssertEqual(store.recommendations.items, [recommend])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, initialDate)
        XCTAssertEqual(persistence.load(for: .following), store.refreshMetadata)
    }

    func testFollowMomentsSuccessUpdatesMetadataAndCancellationKeepsNewTime() async {
        let initialDate = Date(timeIntervalSince1970: 2_500)
        let refreshedDate = initialDate.addingTimeInterval(60)
        let clock = FeedRefreshTestClock(initialDate)
        let initial = feedItem(1)
        let refreshed = feedItem(2)
        let store = FollowNativeStore(
            repository: FollowRepositoryStub(pages: [
                .moments: [
                    .success(FeedPageDTO(items: [initial], nextURL: nil, isEnd: true)),
                    .success(FeedPageDTO(items: [refreshed], nextURL: nil, isEnd: true)),
                    .failure(URLError(.cancelled)),
                ],
            ]),
            refreshMetadataPersistence: InMemoryFeedRefreshMetadataPersistence(),
            now: { clock.now }
        )

        await store.loadMomentsIfNeeded()
        clock.now = refreshedDate
        await store.refresh(section: .moments)

        XCTAssertEqual(store.moments.items, [refreshed])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, refreshedDate)
        XCTAssertFalse(store.isMomentsRefreshing)

        clock.now = refreshedDate.addingTimeInterval(60)
        await store.refresh(section: .moments)

        XCTAssertEqual(store.moments.items, [refreshed])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, refreshedDate)
        XCTAssertFalse(store.isMomentsRefreshing)
        XCTAssertNil(store.moments.errorMessage)
    }

    func testHomeNextFailureKeepsItemsAndRetryDeduplicates() async {
        let first = feedItem(1)
        let second = feedItem(2)
        let next = URL(string: "https://www.zhihu.com/api/v3/next")!
        let repository = HomeRepositoryStub(results: [
            .success(FeedPageDTO(items: [first], nextURL: next, isEnd: false)),
            .failure(HomeFollowTestError.network),
            .success(FeedPageDTO(items: [first, second], nextURL: nil, isEnd: true)),
        ])
        let store = HomeFeedNativeStore(repository: repository)

        await store.loadInitialIfNeeded()
        await store.loadMore()
        XCTAssertEqual(store.items, [first])
        XCTAssertEqual(store.errorMessage, "网络失败")

        await store.retry()
        XCTAssertEqual(store.items, [first, second])
    }

    func testHomeOpenReportsOnlyThroughRepositoryAndDoesNotDelayRouteOwner() async {
        let item = feedItem(9)
        let repository = HomeRepositoryStub(results: [])
        let store = HomeFeedNativeStore(repository: repository)

        store.opened(item)
        for _ in 0..<10 { await Task.yield() }

        let reportedIDs = await repository.reportedIDs()
        XCTAssertEqual(reportedIDs, [item.id])
    }

    func testHomeCancelledNextPageDoesNotPublishRetryError() async {
        let first = feedItem(1)
        let next = URL(string: "https://www.zhihu.com/api/v3/next")!
        let repository = HomeRepositoryStub(results: [
            .success(FeedPageDTO(items: [first], nextURL: next, isEnd: false)),
            .failure(URLError(.cancelled)),
        ])
        let store = HomeFeedNativeStore(repository: repository)

        await store.loadInitialIfNeeded()
        await store.loadMore()

        XCTAssertEqual(store.items, [first])
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.hasNextPage)
    }

    func testFollowKeepsIndependentRecommendationAndMomentPages() async {
        let recommend = feedItem(1)
        let moment = feedItem(2)
        let repository = FollowRepositoryStub(pages: [
            .recommendations: [.success(FeedPageDTO(items: [recommend], nextURL: nil, isEnd: true))],
            .moments: [.success(FeedPageDTO(items: [moment], nextURL: nil, isEnd: true))],
        ])
        let store = FollowNativeStore(repository: repository)

        await store.loadInitialIfNeeded()
        store.select(.moments)
        await store.loadIfNeeded(section: .moments)

        XCTAssertEqual(store.recommendations.items, [recommend])
        XCTAssertEqual(store.moments.items, [moment])
    }

    func testFollowMomentsEntryLoadsOnlyMomentsAndRecentUsers() async {
        let moment = feedItem(3)
        let user = FollowingUserDTO(
            id: "member",
            urlToken: "writer",
            displayName: "作者",
            avatarURL: nil,
            unreadCount: 1
        )
        let repository = FollowMomentsOnlyRepositoryStub(moment: moment, recentUser: user)
        let store = FollowNativeStore(repository: repository)

        await store.loadMomentsIfNeeded()

        XCTAssertEqual(store.moments.items, [moment])
        XCTAssertTrue(store.recommendations.items.isEmpty)
        XCTAssertEqual(store.recentUsers, [user])
        let requestedSections = await repository.requestedSections()
        let recentUserRequestCount = await repository.recentUserRequestCount()
        XCTAssertEqual(requestedSections, [.moments])
        XCTAssertEqual(recentUserRequestCount, 1)
    }

    func testFollowCanLoadMomentsWhileRecommendationsInitialPageIsInFlight() async {
        let recommend = feedItem(1)
        let moment = feedItem(2)
        let repository = FollowSectionConcurrencyRepositoryStub(
            delayedRecommendationRequest: .initial,
            recommendationInitial: FeedPageDTO(items: [recommend], nextURL: nil, isEnd: true),
            momentsInitial: FeedPageDTO(items: [moment], nextURL: nil, isEnd: true)
        )
        let store = FollowNativeStore(repository: repository)

        let recommendationLoad = Task { await store.loadInitialIfNeeded() }
        await repository.waitUntilDelayedRecommendationRequestStarts()
        XCTAssertTrue(store.recommendations.isLoading)

        store.select(.moments)
        await store.loadIfNeeded(section: .moments)

        XCTAssertEqual(store.moments.items, [moment])
        XCTAssertTrue(store.recommendations.isLoading)
        XCTAssertTrue(store.isLoading)
        XCTAssertFalse(store.isRefreshing)

        await repository.resumeDelayedRecommendationRequest()
        await recommendationLoad.value
        XCTAssertEqual(store.recommendations.items, [recommend])
    }

    func testFollowRecommendationAndMomentsPaginationDoNotBlockEachOther() async {
        let recommendationNextURL = URL(string: "https://www.zhihu.com/api/v3/follow/recommendations?page=2")!
        let momentsNextURL = URL(string: "https://www.zhihu.com/api/v3/follow/moments?page=2")!
        let recommendFirst = feedItem(1)
        let recommendSecond = feedItem(2)
        let momentFirst = feedItem(3)
        let momentSecond = feedItem(4)
        let repository = FollowSectionConcurrencyRepositoryStub(
            delayedRecommendationRequest: .nextPage,
            recommendationInitial: FeedPageDTO(
                items: [recommendFirst],
                nextURL: recommendationNextURL,
                isEnd: false
            ),
            momentsInitial: FeedPageDTO(
                items: [momentFirst],
                nextURL: momentsNextURL,
                isEnd: false
            ),
            recommendationNext: FeedPageDTO(items: [recommendSecond], nextURL: nil, isEnd: true),
            momentsNext: FeedPageDTO(items: [momentSecond], nextURL: nil, isEnd: true)
        )
        let store = FollowNativeStore(repository: repository)
        await store.loadIfNeeded(section: .recommendations)
        await store.loadIfNeeded(section: .moments)

        let recommendationPagination = Task { await store.loadMore(section: .recommendations) }
        await repository.waitUntilDelayedRecommendationRequestStarts()
        XCTAssertTrue(store.recommendations.isLoading)

        await store.loadMore(section: .moments)

        XCTAssertEqual(store.moments.items, [momentFirst, momentSecond])
        XCTAssertTrue(store.recommendations.isLoading)

        await repository.resumeDelayedRecommendationRequest()
        await recommendationPagination.value
        XCTAssertEqual(store.recommendations.items, [recommendFirst, recommendSecond])
    }

    private func feedItem(_ id: Int64) -> FeedItemDTO {
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

private final class FeedRefreshTestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class InMemoryFeedRefreshMetadataPersistence: FeedChannelRefreshMetadataPersisting {
    private var values: [FeedRefreshChannelID: FeedChannelRefreshMetadata] = [:]

    func load(for channel: FeedRefreshChannelID) -> FeedChannelRefreshMetadata {
        values[channel] ?? .empty
    }

    func save(_ metadata: FeedChannelRefreshMetadata, for channel: FeedRefreshChannelID) {
        values[channel] = metadata
    }
}

private enum HomeFollowTestError: LocalizedError {
    case network
    var errorDescription: String? { "网络失败" }
}

private actor HomeRepositoryStub: HomeFeedRepository {
    private var results: [Result<FeedPageDTO, Error>]
    private var reported: [FeedItemID] = []

    init(results: [Result<FeedPageDTO, Error>]) { self.results = results }

    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO {
        guard !results.isEmpty else { throw HomeFollowTestError.network }
        return try results.removeFirst().get()
    }

    func reportOpened(_ item: FeedItemDTO) async { reported.append(item.id) }
    func reportedIDs() -> [FeedItemID] { reported }
}

private actor HomePaginationRefreshRepositoryStub: HomeFeedRepository {
    private let initial: FeedPageDTO
    private let paginated: FeedPageDTO
    private let refreshed: FeedPageDTO
    private var requests: [URL?] = []
    private var paginationContinuation: CheckedContinuation<FeedPageDTO, Never>?
    private var paginationStarted = false

    init(initial: FeedPageDTO, paginated: FeedPageDTO, refreshed: FeedPageDTO) {
        self.initial = initial
        self.paginated = paginated
        self.refreshed = refreshed
    }

    func fetchPage(after nextURL: URL?) async throws -> FeedPageDTO {
        requests.append(nextURL)
        switch requests.count {
        case 1:
            return initial
        case 2:
            paginationStarted = true
            return await withCheckedContinuation { continuation in
                paginationContinuation = continuation
            }
        default:
            return refreshed
        }
    }

    func reportOpened(_ item: FeedItemDTO) async {}

    func waitUntilPaginationStarts() async {
        while !paginationStarted { await Task.yield() }
    }

    func resumePagination() {
        paginationContinuation?.resume(returning: paginated)
        paginationContinuation = nil
    }

    func requestedURLs() -> [URL?] { requests }
}

private actor FollowRepositoryStub: FollowRepository {
    private var pages: [FollowSection: [Result<FeedPageDTO, Error>]]

    init(pages: [FollowSection: [Result<FeedPageDTO, Error>]]) { self.pages = pages }

    func fetchPage(section: FollowSection, after nextURL: URL?) async throws -> FeedPageDTO {
        guard var values = pages[section], !values.isEmpty else { throw HomeFollowTestError.network }
        let result = values.removeFirst()
        pages[section] = values
        return try result.get()
    }

    func fetchRecentUsers() async throws -> [FollowingUserDTO] { [] }
}

private actor FollowMomentsOnlyRepositoryStub: FollowRepository {
    private let moment: FeedItemDTO
    private let recentUser: FollowingUserDTO
    private var sections: [FollowSection] = []
    private var recentUserRequests = 0

    init(moment: FeedItemDTO, recentUser: FollowingUserDTO) {
        self.moment = moment
        self.recentUser = recentUser
    }

    func fetchPage(section: FollowSection, after nextURL: URL?) async throws -> FeedPageDTO {
        sections.append(section)
        return FeedPageDTO(items: [moment], nextURL: nil, isEnd: true)
    }

    func fetchRecentUsers() async throws -> [FollowingUserDTO] {
        recentUserRequests += 1
        return [recentUser]
    }

    func requestedSections() -> [FollowSection] { sections }
    func recentUserRequestCount() -> Int { recentUserRequests }
}

private actor FollowSectionConcurrencyRepositoryStub: FollowRepository {
    enum DelayedRecommendationRequest {
        case initial
        case nextPage
    }

    private let delayedRecommendationRequest: DelayedRecommendationRequest
    private let recommendationInitial: FeedPageDTO
    private let momentsInitial: FeedPageDTO
    private let recommendationNext: FeedPageDTO?
    private let momentsNext: FeedPageDTO?
    private var delayedRecommendationContinuation: CheckedContinuation<FeedPageDTO, Error>?
    private var delayedRecommendationRequestStarted = false

    init(
        delayedRecommendationRequest: DelayedRecommendationRequest,
        recommendationInitial: FeedPageDTO,
        momentsInitial: FeedPageDTO,
        recommendationNext: FeedPageDTO? = nil,
        momentsNext: FeedPageDTO? = nil
    ) {
        self.delayedRecommendationRequest = delayedRecommendationRequest
        self.recommendationInitial = recommendationInitial
        self.momentsInitial = momentsInitial
        self.recommendationNext = recommendationNext
        self.momentsNext = momentsNext
    }

    func fetchPage(section: FollowSection, after nextURL: URL?) async throws -> FeedPageDTO {
        switch (section, nextURL) {
        case (.recommendations, nil):
            if delayedRecommendationRequest == .initial {
                return try await suspendRecommendationRequest()
            }
            return recommendationInitial
        case (.moments, nil):
            return momentsInitial
        case (.recommendations, .some):
            guard let recommendationNext else { throw HomeFollowTestError.network }
            if delayedRecommendationRequest == .nextPage {
                return try await suspendRecommendationRequest()
            }
            return recommendationNext
        case (.moments, .some):
            guard let momentsNext else { throw HomeFollowTestError.network }
            return momentsNext
        }
    }

    func fetchRecentUsers() async throws -> [FollowingUserDTO] { [] }

    func waitUntilDelayedRecommendationRequestStarts() async {
        while !delayedRecommendationRequestStarted { await Task.yield() }
    }

    func resumeDelayedRecommendationRequest() {
        let page = delayedRecommendationRequest == .initial
            ? recommendationInitial
            : recommendationNext
        guard let page else { return }
        delayedRecommendationContinuation?.resume(returning: page)
        delayedRecommendationContinuation = nil
    }

    private func suspendRecommendationRequest() async throws -> FeedPageDTO {
        delayedRecommendationRequestStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            delayedRecommendationContinuation = continuation
        }
    }
}
