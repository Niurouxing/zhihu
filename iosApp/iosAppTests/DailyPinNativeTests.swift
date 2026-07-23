import Foundation
import XCTest
@testable import iosApp

final class DailyNativeContractTests: XCTestCase {
    func testDailyOriginParserFindsOriginLinkAndRoutesAnswer() throws {
        let html = #"<a class="originUrl" href="https://www.zhihu.com/question/7/answer/42">查看原文</a>"#
        let url = try XCTUnwrap(DailyHTMLOriginParser.originURL(in: html))

        XCTAssertEqual(
            DailyRouteResolver.destination(url: url, fallbackTitle: "问题"),
            .feed(.answer(answerID: 42, questionID: 7, questionTitle: "问题"))
        )
    }

    func testDailyUnrecognizedOriginRemainsRealExternalDestination() throws {
        let url = URL(string: "https://zhuanlan.zhihu.com/special/weekly")!
        XCTAssertEqual(DailyRouteResolver.destination(url: url, fallbackTitle: "日报"), .external(url))
    }
}

@MainActor
final class DailyNativeStoreRefreshTests: XCTestCase {
    func testDailyLatestSuccessUpdatesMetadataButPaginationAndFailureDoNot() async {
        let initialDate = Date(timeIntervalSince1970: 4_000)
        var now = initialDate
        let suite = "DailyRefreshMetadataTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = UserDefaultsFeedChannelRefreshMetadataPersistence(defaults: defaults)
        let latest = DailySectionDTO(date: "20260722", stories: [dailyStory(1)])
        let older = DailySectionDTO(date: "20260721", stories: [dailyStory(2)])
        let repository = DailyRefreshRepositoryStub(
            latestResults: [.success(latest), .failure(DailyRefreshTestError.network)],
            beforeResults: [.success(older)]
        )
        let store = DailyNativeStore(
            repository: repository,
            refreshMetadataPersistence: persistence,
            now: { now }
        )

        await store.loadInitialIfNeeded()
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, initialDate)

        now = initialDate.addingTimeInterval(10)
        await store.loadMore()
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, initialDate)

        now = initialDate.addingTimeInterval(20)
        await store.refresh()
        XCTAssertEqual(store.sections, [latest, older])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, initialDate)
        XCTAssertEqual(persistence.load(for: .daily), store.refreshMetadata)
    }

    func testDailySuccessfulRefreshUpdatesMetadataAndCancellationKeepsNewTime() async {
        let initialDate = Date(timeIntervalSince1970: 4_500)
        let refreshedDate = initialDate.addingTimeInterval(60)
        var now = initialDate
        let suite = "DailySuccessfulRefreshTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = DailySectionDTO(date: "20260722", stories: [dailyStory(1)])
        let refreshed = DailySectionDTO(date: "20260723", stories: [dailyStory(2)])
        let store = DailyNativeStore(
            repository: DailyRefreshRepositoryStub(
                latestResults: [
                    .success(initial),
                    .success(refreshed),
                    .failure(URLError(.cancelled)),
                ],
                beforeResults: []
            ),
            refreshMetadataPersistence: UserDefaultsFeedChannelRefreshMetadataPersistence(
                defaults: defaults
            ),
            now: { now }
        )

        await store.loadInitialIfNeeded()
        now = refreshedDate
        await store.refresh()

        XCTAssertEqual(store.sections, [refreshed])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, refreshedDate)
        XCTAssertFalse(store.isRefreshing)

        now = refreshedDate.addingTimeInterval(60)
        await store.refresh()

        XCTAssertEqual(store.sections, [refreshed])
        XCTAssertEqual(store.refreshMetadata.lastSuccessfulRefreshAt, refreshedDate)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNil(store.errorMessage)
    }

    func testDailyURLCancellationDoesNotPublishFooterError() async {
        let latest = DailySectionDTO(date: "20260722", stories: [dailyStory(1)])
        let repository = DailyRefreshRepositoryStub(
            latestResults: [.success(latest)],
            beforeResults: [.failure(URLError(.cancelled))]
        )
        let store = DailyNativeStore(repository: repository)

        await store.loadInitialIfNeeded()
        await store.loadMore()

        XCTAssertEqual(store.sections, [latest])
        XCTAssertEqual(store.nextPageLoadID, latest.date)
        XCTAssertFalse(store.isLoadingMore)
        XCTAssertNil(store.errorMessage)
    }

    func testDailyInitialURLCancellationLeavesSilentRetryableState() async {
        let repository = DailyRefreshRepositoryStub(
            latestResults: [.failure(URLError(.cancelled))],
            beforeResults: []
        )
        let store = DailyNativeStore(repository: repository)

        await store.loadInitialIfNeeded()

        XCTAssertTrue(store.sections.isEmpty)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    func testDailyRealPaginationFailureKeepsFriendlyRetryError() async {
        let latest = DailySectionDTO(date: "20260722", stories: [dailyStory(1)])
        let repository = DailyRefreshRepositoryStub(
            latestResults: [.success(latest)],
            beforeResults: [.failure(DailyRefreshTestError.network)]
        )
        let store = DailyNativeStore(repository: repository)

        await store.loadInitialIfNeeded()
        await store.loadMore()

        XCTAssertEqual(store.sections, [latest])
        XCTAssertFalse(store.isLoadingMore)
        XCTAssertEqual(store.errorMessage, "网络失败，请重试")
    }

    private func dailyStory(_ id: Int64) -> DailyStoryDTO {
        DailyStoryDTO(
            id: id,
            title: "日报 \(id)",
            sourceURL: URL(string: "https://daily.zhihu.com/story/\(id)")!,
            hint: "日报",
            imageURL: nil
        )
    }
}

private enum DailyRefreshTestError: LocalizedError {
    case network

    var errorDescription: String? { "网络失败，请重试" }
}

private actor DailyRefreshRepositoryStub: DailyRepository {
    private var latestResults: [Result<DailySectionDTO, Error>]
    private var beforeResults: [Result<DailySectionDTO, Error>]

    init(
        latestResults: [Result<DailySectionDTO, Error>],
        beforeResults: [Result<DailySectionDTO, Error>]
    ) {
        self.latestResults = latestResults
        self.beforeResults = beforeResults
    }

    func fetchLatest() async throws -> DailySectionDTO {
        guard !latestResults.isEmpty else { throw DailyRefreshTestError.network }
        return try latestResults.removeFirst().get()
    }

    func fetchBefore(_ date: String) async throws -> DailySectionDTO {
        guard !beforeResults.isEmpty else { throw DailyRefreshTestError.network }
        return try beforeResults.removeFirst().get()
    }

    func resolveDestination(for story: DailyStoryDTO) async -> DailyStoryDestination {
        .external(story.sourceURL)
    }
}

final class PinNativeContractTests: XCTestCase {
    func testPinMapperPreservesBlocksPollRelationshipAndCounts() throws {
        let data = Data(
            #"{"id":"12","url":"https://www.zhihu.com/pin/12","author":{"id":"member","url_token":"writer","name":"作者","avatar_url":"https://pic.zhimg.com/a.jpg","headline":"简介"},"content":[{"type":"text","content":"<p>正文 <a href=\"https://www.zhihu.com/question/7\">问题</a></p>"},{"type":"image","url":"https://pic.zhimg.com/p.jpg"}],"created":10,"updated":20,"like_count":4,"comment_count":5,"virtuals":{"is_liked":true},"topics":[{"name":"iOS"}],"bottom_poll":{"voting":{"id":"8","title":"选择","member_count":2,"is_voted":false,"end_at":-1,"options":[{"id":"1","title":"A","voting_count":2}]}}}"#.utf8
        )

        let detail = try PinResponseMapper.detail(from: data, expectedID: 12)

        XCTAssertEqual(detail.author.displayName, "作者")
        XCTAssertEqual(detail.blocks.count, 2)
        XCTAssertTrue(detail.isLiked)
        XCTAssertEqual(detail.likeCount, 4)
        XCTAssertEqual(detail.commentCount, 5)
        XCTAssertEqual(detail.topics, ["iOS"])
        XCTAssertTrue(detail.poll?.acceptsVote == true)
    }

    func testPinHTMLParserKeepsFirstSeenLinkOrderWithoutDuplicates() {
        let first = "https://www.zhihu.com/question/1"
        let second = "https://www.zhihu.com/question/2"
        let result = PinHTMLParser.parse(
            #"<a href="https://www.zhihu.com/question/1">一</a><a href="https://www.zhihu.com/question/2">二</a><a href="https://www.zhihu.com/question/1">一</a>"#
        )
        XCTAssertEqual(result.links.map(\.absoluteString), [first, second])
    }
}
