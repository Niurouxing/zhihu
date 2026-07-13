import Foundation
import XCTest
@testable import iosApp

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

    func testFeedMapperRejectsUntrustedPagingURL() throws {
        let data = Data(#"{"data":[],"paging":{"is_end":false,"next":"https://evil.example/steal"}}"#.utf8)
        XCTAssertThrowsError(try FeedResponseMapper.page(from: data, policy: .search))
    }

    func testHomeFollowRequestKeepsExistingQueryAndAddsPagingParametersOnce() throws {
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
