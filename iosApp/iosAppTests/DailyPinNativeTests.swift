import Foundation
import XCTest
@testable import iosApp

final class DailyNativeContractTests: XCTestCase {
    override func tearDown() {
        DailyURLProtocol.setHandler(nil)
        super.tearDown()
    }

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

    func testDailyAppViewOriginsUseTypedNativeDestinations() throws {
        XCTAssertEqual(
            DailyRouteResolver.destination(
                url: URL(string: "https://www.zhihu.com/appview/pin/11")!,
                fallbackTitle: "想法"
            ),
            .feed(.pin(pinID: 11))
        )
        XCTAssertEqual(
            DailyRouteResolver.destination(
                url: URL(string: "https://www.zhihu.com/appview/answer/12")!,
                fallbackTitle: "回答"
            ),
            .feed(.answer(answerID: 12, questionID: nil, questionTitle: "回答"))
        )
        XCTAssertEqual(
            DailyRouteResolver.destination(
                url: URL(string: "https://www.zhihu.com/appview/p/13")!,
                fallbackTitle: "文章"
            ),
            .feed(.article(articleID: 13, title: "文章"))
        )

        let lookalike = URL(string: "https://attacker.example/appview/pin/11")!
        XCTAssertEqual(
            DailyRouteResolver.destination(url: lookalike, fallbackTitle: "不可信"),
            .external(lookalike)
        )
    }

    func testDailyRepositoryPreservesResolvedOriginRouting() async throws {
        let body = #"<a class="originUrl" href="https://www.zhihu.com/question/7/answer/42">查看原文</a>"#
        let payload = try JSONSerialization.data(withJSONObject: ["body": body])
        DailyURLProtocol.setHandler { _ in (200, payload) }
        let repository = makeDailyRepository()

        let resolution = await repository.resolveDestination(for: dailyResolutionStory())

        XCTAssertEqual(
            resolution,
            .destination(.feed(.answer(answerID: 42, questionID: 7, questionTitle: "日报标题")))
        )
    }

    func testDailyRepositoryExposesMissingBodyFailure() async {
        DailyURLProtocol.setHandler { _ in (200, Data(#"{"title":"日报"}"#.utf8)) }
        let story = dailyResolutionStory()
        let repository = makeDailyRepository()

        let resolution = await repository.resolveDestination(for: story)

        XCTAssertEqual(
            resolution,
            .failure(.init(storyID: story.id, sourceURL: story.sourceURL, reason: .missingBody))
        )
    }

    func testDailyRepositoryExposesMissingOriginFailure() async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["body": "<p>没有原文链接</p>"])
        DailyURLProtocol.setHandler { _ in (200, payload) }
        let story = dailyResolutionStory()
        let repository = makeDailyRepository()

        let resolution = await repository.resolveDestination(for: story)

        XCTAssertEqual(
            resolution,
            .failure(.init(storyID: story.id, sourceURL: story.sourceURL, reason: .missingOrigin))
        )
    }

    private func makeDailyRepository() -> URLSessionDailyRepository {
        URLSessionDailyRepository(
            client: ZhihuAPIClient(
                accountStore: DailyAccountStore(),
                session: makeDailySession()
            )
        )
    }

    private func dailyResolutionStory() -> DailyStoryDTO {
        DailyStoryDTO(
            id: 12,
            title: "日报标题",
            sourceURL: URL(string: "https://daily.zhihu.com/story/12")!,
            hint: "日报",
            imageURL: nil
        )
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

    func testDailyAccountChangeClearsContentAndAllowsFreshLoad() async {
        let suite = "DailyAccountIsolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DailySectionDTO(date: "20260722", stories: [dailyStory(1)])
        let second = DailySectionDTO(date: "20260723", stories: [dailyStory(2)])
        let persistence = UserDefaultsFeedChannelRefreshMetadataPersistence(defaults: defaults)
        let store = DailyNativeStore(
            repository: DailyRefreshRepositoryStub(
                latestResults: [.success(first), .success(second)],
                beforeResults: []
            ),
            refreshMetadataPersistence: persistence
        )
        await store.loadInitialIfNeeded()

        store.accountDidChange()

        XCTAssertTrue(store.sections.isEmpty)
        XCTAssertEqual(store.refreshMetadata, .empty)
        XCTAssertEqual(persistence.load(for: .daily), .empty)
        await store.loadInitialIfNeeded()
        XCTAssertEqual(store.sections, [second])
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

    func resolveDestination(for story: DailyStoryDTO) async -> DailyStoryResolution {
        .destination(.external(story.sourceURL))
    }
}

private func makeDailySession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DailyURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class DailyURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var storedHandler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.lock()
        storedHandler = handler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.storedHandler
        Self.lock.unlock()
        guard let handler else { return }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class DailyAccountStore: AccountJSONStore, @unchecked Sendable {
    func load() throws -> String? { nil }
    func save(_ accountJSON: String) throws {}
    func clear() throws {}
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
        guard case let .text(_, text, _) = detail.blocks.first else {
            return XCTFail("Expected the first pin block to be text")
        }
        XCTAssertEqual(text, "正文 问题")
    }

    func testPinHTMLParserDecodesChineseAsUTF8() {
        let result = PinHTMLParser.parse("<p>新举措。效果如何，拭目以待吧。</p>")

        XCTAssertEqual(result.text, "新举措。效果如何，拭目以待吧。")
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
