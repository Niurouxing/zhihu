import XCTest
@testable import iosApp

@MainActor
final class NativeLibraryFeatureTests: XCTestCase {
    func testDestinationResolverMatchesExistingZhihuRouteContract() {
        XCTAssertEqual(
            NativeContentDestinationResolver.resolve("https://www.zhihu.com/question/1/answer/2"),
            .article(id: 2, kind: .answer)
        )
        XCTAssertEqual(
            NativeContentDestinationResolver.resolve("https://zhuanlan.zhihu.com/p/3"),
            .article(id: 3, kind: .article)
        )
        XCTAssertEqual(
            NativeContentDestinationResolver.resolve("zhihu://questions/4"),
            .question(id: 4)
        )
        XCTAssertEqual(
            NativeContentDestinationResolver.resolve("https://www.zhihu.com/special/1575482655944171520?native=0"),
            .special(id: "1575482655944171520")
        )
        XCTAssertEqual(
            NativeContentDestinationResolver.resolve("https://www.zhihu.com/column/c_1533471233991028736"),
            .column(id: "c_1533471233991028736")
        )
        XCTAssertNil(NativeContentDestinationResolver.resolve("file:///private/secret"))
    }

    func testDestinationResolverMapsTrustedAppViewRoutesAndDoesNotTypeLookalikes() {
        XCTAssertEqual(
            NativeContentDestinationResolver.resolve("https://www.zhihu.com/appview/pin/11"),
            .pin(id: 11)
        )
        XCTAssertEqual(
            NativeContentDestinationResolver.resolve("https://www.zhihu.com/appview/answer/12"),
            .article(id: 12, kind: .answer)
        )
        XCTAssertEqual(
            NativeContentDestinationResolver.resolve("https://www.zhihu.com/appview/p/13"),
            .article(id: 13, kind: .article)
        )

        let unknown = URL(string: "https://www.zhihu.com/appview/special/13")!
        XCTAssertEqual(NativeContentDestinationResolver.resolve(unknown.absoluteString), .external(unknown))
        XCTAssertNil(NativeContentDestinationResolver.resolve("https://attacker.example/appview/answer/12"))
        XCTAssertNil(NativeContentDestinationResolver.resolve("https://attacker.example/column/c_1533471233991028736"))

        let malformedColumn = URL(string: "https://www.zhihu.com/column/not-a-column")!
        XCTAssertEqual(
            NativeContentDestinationResolver.resolve(malformedColumn.absoluteString),
            .external(malformedColumn)
        )
    }

    func testCollectionsStoreDeduplicatesStableIDsAcrossPages() async {
        var calls = 0
        let repository = NativeLibraryRepository(
            fetchCollections: { _, _ in
                calls += 1
                if calls == 1 {
                    return NativePage(
                        items: [NativeLibraryCollection(id: "1", title: "One")],
                        paging: NativePaging(next: URL(string: "https://www.zhihu.com/next"), isEnd: false)
                    )
                }
                return NativePage(
                    items: [
                        NativeLibraryCollection(id: "1", title: "Duplicate"),
                        NativeLibraryCollection(id: "2", title: "Two"),
                    ],
                    paging: NativePaging(next: nil, isEnd: true)
                )
            },
            fetchCollection: { _ in NativeLibraryCollection(id: "1", title: "One") },
            fetchCollectionItems: { _, _ in NativePage(items: [], paging: NativePaging(next: nil, isEnd: true)) },
            fetchHistory: { _ in NativePage(items: [], paging: NativePaging(next: nil, isEnd: true)) },
            clearHistory: {}
        )
        let store = NativeCollectionsStore(userToken: "alice", repository: repository)

        await store.refresh()
        await store.loadMore()

        XCTAssertEqual(store.collections.map(\.id), ["1", "2"])
        XCTAssertTrue(store.isEnd)
    }

    func testHistoryClearFailurePreservesVisibleItems() async {
        enum Failure: Error { case rejected }
        let item = NativeHistoryItem(
            id: "answer:1",
            title: "Title",
            summary: "",
            detail: "回答",
            authorName: nil,
            coverURL: nil,
            readTime: 1,
            destination: .article(id: 1, kind: .answer)
        )
        let repository = NativeLibraryRepository(
            fetchCollections: { _, _ in NativePage(items: [], paging: NativePaging(next: nil, isEnd: true)) },
            fetchCollection: { _ in NativeLibraryCollection(id: "1", title: "One") },
            fetchCollectionItems: { _, _ in NativePage(items: [], paging: NativePaging(next: nil, isEnd: true)) },
            fetchHistory: { _ in NativePage(items: [item], paging: NativePaging(next: nil, isEnd: true)) },
            clearHistory: { throw Failure.rejected }
        )
        let store = NativeHistoryStore(repository: repository)

        await store.refresh()
        let cleared = await store.clear()

        XCTAssertFalse(cleared)
        XCTAssertEqual(store.items, [item])
        XCTAssertNotNil(store.errorMessage)
    }

    func testHistoryStoreTreatsMissingNextURLAsEnd() async {
        var calls = 0
        let item = NativeHistoryItem(
            id: "answer:1",
            title: "Title",
            summary: "",
            detail: "回答",
            authorName: nil,
            coverURL: nil,
            readTime: 1,
            destination: .article(id: 1, kind: .answer)
        )
        let repository = NativeLibraryRepository(
            fetchCollections: { _, _ in NativePage(items: [], paging: NativePaging(next: nil, isEnd: true)) },
            fetchCollection: { _ in NativeLibraryCollection(id: "1", title: "One") },
            fetchCollectionItems: { _, _ in NativePage(items: [], paging: NativePaging(next: nil, isEnd: true)) },
            fetchHistory: { _ in
                calls += 1
                return NativePage(items: [item], paging: NativePaging(next: nil, isEnd: false))
            },
            clearHistory: {}
        )
        let store = NativeHistoryStore(repository: repository)

        await store.refresh()
        await store.loadMore()

        XCTAssertEqual(calls, 1)
        XCTAssertTrue(store.isEnd)
        XCTAssertFalse(store.canLoadMore)
        XCTAssertFalse(store.isLoadingMore)
    }

    func testHistoryStoreStopsWhenServerRepeatsNextURL() async {
        let repeatedPage = URL(string: "https://api.zhihu.com/unify-consumption/read_history?offset=10&limit=10")!
        var requestedURLs: [URL?] = []
        let first = NativeHistoryItem(
            id: "answer:1",
            title: "First",
            summary: "",
            detail: "回答",
            authorName: nil,
            coverURL: nil,
            readTime: 2,
            destination: .article(id: 1, kind: .answer)
        )
        let second = NativeHistoryItem(
            id: "answer:2",
            title: "Second",
            summary: "",
            detail: "回答",
            authorName: nil,
            coverURL: nil,
            readTime: 1,
            destination: .article(id: 2, kind: .answer)
        )
        let repository = NativeLibraryRepository(
            fetchCollections: { _, _ in NativePage(items: [], paging: NativePaging(next: nil, isEnd: true)) },
            fetchCollection: { _ in NativeLibraryCollection(id: "1", title: "One") },
            fetchCollectionItems: { _, _ in NativePage(items: [], paging: NativePaging(next: nil, isEnd: true)) },
            fetchHistory: { requestedURL in
                requestedURLs.append(requestedURL)
                if requestedURL == nil {
                    return NativePage(items: [first], paging: NativePaging(next: repeatedPage, isEnd: false))
                }
                return NativePage(items: [second], paging: NativePaging(next: repeatedPage, isEnd: false))
            },
            clearHistory: {}
        )
        let store = NativeHistoryStore(repository: repository)

        await store.refresh()
        await store.loadMore()
        await store.loadMore()

        XCTAssertEqual(requestedURLs, [nil, repeatedPage])
        XCTAssertEqual(store.items, [first, second])
        XCTAssertTrue(store.isEnd)
        XCTAssertFalse(store.canLoadMore)
        XCTAssertFalse(store.isLoadingMore)
    }

    func testSpecialPayloadMapsMetadataSectionsAndNativeRoutesLossily() throws {
        let data = Data(
            #"""
            {
              "id": "1575482655944171520",
              "title": "每周看点",
              "introduction": "本周精选",
              "banner": "https://pic1.zhimg.com/banner.png",
              "content_count": 4,
              "view_count": 12000,
              "followers_count": 160,
              "updated": 1668406956,
              "selected_contents": [{
                "id": "group-1",
                "title": "深度剖析",
                "content": [{
                  "id": "section-1",
                  "title": "热门内容",
                  "content": [
                    {
                      "id": "565147700",
                      "type": "question",
                      "title": "一个问题",
                      "excerpt": "问题摘要",
                      "tags": [{"name": "回答", "value": 42}]
                    },
                    {
                      "id": "2755441542",
                      "type": "answer",
                      "title": "一个回答",
                      "excerpt": "回答摘要",
                      "author": {"name": "答主"},
                      "tags": [{"name": "赞同", "value": 88}]
                    },
                    {
                      "id": "1574456893635796992",
                      "type": "zvideo",
                      "title": "一个视频",
                      "image_path": "https://pic2.zhimg.com/video.jpg",
                      "video_token": "1574456785066569728",
                      "tags": [{"name": "播放", "value": 999}]
                    },
                    {
                      "id": "unknown-1",
                      "type": "future_type",
                      "title": "未知内容",
                      "tags": []
                    },
                    "无法解析的成员"
                  ]
                }]
              }]
            }
            """#.utf8
        )

        let special = try NativeSpecialRepository.decodeSpecial(data)

        XCTAssertEqual(special.id, "1575482655944171520")
        XCTAssertEqual(special.title, "每周看点")
        XCTAssertEqual(special.contentCount, 4)
        XCTAssertEqual(special.groups[0].title, "深度剖析")
        XCTAssertEqual(special.sections.count, 1)
        XCTAssertEqual(special.sections[0].items.count, 4)
        XCTAssertEqual(
            special.sections[0].items[0].route,
            .question(questionID: 565147700, title: "一个问题")
        )
        XCTAssertEqual(
            special.sections[0].items[1].route,
            .answer(answerID: 2755441542, questionID: nil, questionTitle: "一个回答")
        )
        guard case let .video(videoRoute)? = special.sections[0].items[2].route else {
            return XCTFail("Expected a native video route")
        }
        XCTAssertEqual(videoRoute.contentID, 1574456893635796992)
        XCTAssertEqual(videoRoute.videoID, 1574456785066569728)
        XCTAssertNil(special.sections[0].items[3].route)
    }

    func testSpecialStorePreservesLoadedPageWhenRefreshFails() async {
        enum Failure: Error { case offline }
        var calls = 0
        let loaded = NativeSpecialDetail(
            id: "1",
            title: "专题",
            introduction: "",
            bannerURL: nil,
            contentCount: 0,
            viewCount: 0,
            followersCount: 0,
            updatedTime: 0,
            groups: []
        )
        let store = NativeSpecialStore(
            specialID: "1",
            repository: NativeSpecialRepository(fetchSpecial: { _ in
                calls += 1
                if calls == 1 { return loaded }
                throw Failure.offline
            })
        )

        await store.refresh()
        await store.refresh()

        XCTAssertEqual(store.special, loaded)
        XCTAssertNotNil(store.errorMessage)
    }

    func testColumnPayloadMapsMetadataAndMixedNativeItems() throws {
        let column = try NativeColumnRepository.decodeColumn(Data(
            #"""
            {
              "id": "c_1533471233991028736",
              "title": "国际学术会议",
              "description": "专栏说明",
              "image_url": "https://pic1.zhimg.com/column.png",
              "items_count": 18,
              "followers": 120,
              "voteup_count": 360,
              "author": {
                "name": "专栏作者",
                "url_token": "column-author",
                "avatar_url": "https://pic1.zhimg.com/avatar.png"
              }
            }
            """#.utf8
        ))
        let page = try NativeColumnRepository.decodeItems(Data(
            #"""
            {
              "data": [
                {
                  "type": "answer",
                  "id": "42",
                  "excerpt": "回答摘要",
                  "voteup_count": 12,
                  "comment_count": 3,
                  "question": {"title": "回答所属问题"},
                  "author": {"name": "答主", "avatar_url": "https://pic1.zhimg.com/a.png"}
                },
                {
                  "type": "article",
                  "id": 43,
                  "title": "专栏文章",
                  "excerpt": "文章摘要",
                  "voteup_count": 9,
                  "comment_count": 2,
                  "author": {"name": "作者", "avatar_url": "https://pic1.zhimg.com/b.png"}
                },
                "无法解析的成员"
              ],
              "paging": {
                "is_end": false,
                "next": "http://www.zhihu.com/api/v4/columns/c_1533471233991028736/items?limit=10&offset=10"
              }
            }
            """#.utf8
        ))

        XCTAssertEqual(column.title, "国际学术会议")
        XCTAssertEqual(column.itemCount, 18)
        XCTAssertEqual(column.author?.urlToken, "column-author")
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].destination, .article(id: 42, kind: .answer))
        XCTAssertEqual(page.items[1].destination, .article(id: 43, kind: .article))
        XCTAssertEqual(page.paging.next?.scheme, "https")
        XCTAssertFalse(page.paging.isEnd)
    }

    func testColumnRequestsReuseAvailableAccountSession() async throws {
        let recorder = NativeColumnRequestRecorder()
        NativeColumnURLProtocol.setHandler { request in
            recorder.record(request)
            if request.url?.path.hasSuffix("/items") == true {
                return (
                    200,
                    Data(#"{"data":[],"paging":{"is_end":true,"next":null}}"#.utf8),
                    [:]
                )
            }
            return (
                200,
                Data(#"{"id":"c_1533471233991028736","title":"专栏"}"#.utf8),
                [:]
            )
        }
        defer { NativeColumnURLProtocol.setHandler(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeColumnURLProtocol.self]
        let client = ZhihuAPIClient(
            accountStore: NativeColumnAccountStore(
                json: #"{"cookies":{"d_c0":"device-cookie","z_c0":"login-cookie"},"userAgent":"test-agent"}"#
            ),
            session: URLSession(configuration: configuration)
        )
        let repository = NativeColumnRepository.live(client: client)

        _ = try await repository.fetchColumn("c_1533471233991028736")
        _ = try await repository.fetchItems("c_1533471233991028736", nil)

        XCTAssertEqual(recorder.requests.count, 2)
        for request in recorder.requests {
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("z_c0=login-cookie") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-zse-93"), ZhihuRequestSignature.zse93)
            XCTAssertTrue(request.value(forHTTPHeaderField: "x-zse-96")?.hasPrefix("2.0_") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "test-agent")
        }
    }

    func testColumnStoreDeduplicatesItemsAcrossPages() async {
        let column = NativeColumnDetail(
            id: "c_1",
            title: "专栏",
            description: "",
            imageURL: nil,
            itemCount: 2,
            followersCount: 0,
            voteupCount: 0,
            author: nil
        )
        let first = NativeLibraryItem(
            id: "answer:1",
            title: "一",
            summary: "",
            detail: "",
            authorName: nil,
            avatarURL: nil,
            destination: .article(id: 1, kind: .answer)
        )
        let second = NativeLibraryItem(
            id: "article:2",
            title: "二",
            summary: "",
            detail: "",
            authorName: nil,
            avatarURL: nil,
            destination: .article(id: 2, kind: .article)
        )
        var calls = 0
        let store = NativeColumnStore(
            columnID: "c_1",
            repository: NativeColumnRepository(
                fetchColumn: { _ in column },
                fetchItems: { _, _ in
                    calls += 1
                    if calls == 1 {
                        return NativePage(
                            items: [first],
                            paging: NativePaging(
                                next: URL(string: "https://www.zhihu.com/next"),
                                isEnd: false
                            )
                        )
                    }
                    return NativePage(
                        items: [first, second],
                        paging: NativePaging(next: nil, isEnd: true)
                    )
                }
            )
        )

        await store.refresh()
        await store.loadMore()

        XCTAssertEqual(store.column, column)
        XCTAssertEqual(store.items.map(\.id), ["answer:1", "article:2"])
        XCTAssertTrue(store.isEnd)
        XCTAssertFalse(store.isLoadingMore)
    }

    func testColumnStoreTreatsMissingNextURLAsEnd() async {
        let column = NativeColumnDetail(
            id: "c_1",
            title: "专栏",
            description: "",
            imageURL: nil,
            itemCount: 1,
            followersCount: 0,
            voteupCount: 0,
            author: nil
        )
        let item = NativeLibraryItem(
            id: "answer:1",
            title: "一",
            summary: "",
            detail: "",
            authorName: nil,
            avatarURL: nil,
            destination: .article(id: 1, kind: .answer)
        )
        var calls = 0
        let store = NativeColumnStore(
            columnID: "c_1",
            repository: NativeColumnRepository(
                fetchColumn: { _ in column },
                fetchItems: { _, _ in
                    calls += 1
                    return NativePage(
                        items: [item],
                        paging: NativePaging(next: nil, isEnd: false)
                    )
                }
            )
        )

        await store.refresh()
        await store.loadMore()

        XCTAssertEqual(calls, 1)
        XCTAssertTrue(store.isEnd)
        XCTAssertFalse(store.canLoadMore)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.isLoadingMore)
    }

    func testColumnStoreStopsWhenServerRepeatsPagingURL() async {
        let column = NativeColumnDetail(
            id: "c_1",
            title: "专栏",
            description: "",
            imageURL: nil,
            itemCount: 2,
            followersCount: 0,
            voteupCount: 0,
            author: nil
        )
        let first = NativeLibraryItem(
            id: "answer:1",
            title: "一",
            summary: "",
            detail: "",
            authorName: nil,
            avatarURL: nil,
            destination: .article(id: 1, kind: .answer)
        )
        let repeatedPage = URL(string: "https://www.zhihu.com/next")!
        var calls = 0
        let store = NativeColumnStore(
            columnID: "c_1",
            repository: NativeColumnRepository(
                fetchColumn: { _ in column },
                fetchItems: { _, next in
                    calls += 1
                    return NativePage(
                        items: [first],
                        paging: NativePaging(
                            next: calls == 1 ? repeatedPage : next,
                            isEnd: false
                        )
                    )
                }
            )
        )

        await store.refresh()
        await store.loadMore()
        await store.loadMore()

        XCTAssertEqual(calls, 2)
        XCTAssertTrue(store.isEnd)
        XCTAssertFalse(store.canLoadMore)
        XCTAssertFalse(store.isLoadingMore)
    }

    func testClipboardParserFindsSupportedZhihuContentInsideSharedText() {
        let candidate = NativeClipboardZhihuLinkParser.candidate(
            from: "推荐这个回答：https://www.zhihu.com/question/1/answer/42?utm_source=share"
        )

        XCTAssertEqual(candidate?.url.host, "www.zhihu.com")
        XCTAssertEqual(candidate?.destination, .article(id: 42, kind: .answer))
        XCTAssertEqual(candidate?.contentKey, "answer:42")
    }

    func testClipboardParserIgnoresPlainTextExternalAndUnsupportedZhihuLinks() {
        XCTAssertNil(NativeClipboardZhihuLinkParser.candidate(from: "只是普通文本"))
        XCTAssertNil(NativeClipboardZhihuLinkParser.candidate(from: "https://example.com/question/1"))
        XCTAssertNil(NativeClipboardZhihuLinkParser.candidate(from: "https://www.zhihu.com/api/v4/me"))
    }

    func testClipboardParserRecognizesNativeSpecialLandingPage() {
        let candidate = NativeClipboardZhihuLinkParser.candidate(
            from: "https://www.zhihu.com/special/1575482655944171520"
        )

        XCTAssertEqual(candidate?.destination, .special(id: "1575482655944171520"))
        XCTAssertEqual(candidate?.contentKey, "special:1575482655944171520")
    }

    func testClipboardParserRecognizesNativeColumnLandingPage() {
        let candidate = NativeClipboardZhihuLinkParser.candidate(
            from: "https://www.zhihu.com/column/c_1533471233991028736"
        )

        XCTAssertEqual(candidate?.destination, .column(id: "c_1533471233991028736"))
        XCTAssertEqual(candidate?.contentKey, "column:c_1533471233991028736")
    }

    func testClipboardPromptHistoryRecordsOnceAndKeepsBoundedRecentKeys() throws {
        let suiteName = "NativeClipboardPromptHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let history = NativeClipboardPromptHistory(defaults: defaults, key: "history")

        history.record("answer:1")
        history.record("answer:1")
        for value in 2 ... 45 {
            history.record("answer:\(value)")
        }

        XCTAssertFalse(history.contains("answer:1"))
        XCTAssertTrue(history.contains("answer:45"))
        XCTAssertEqual(defaults.stringArray(forKey: "history")?.count, 40)
    }

    func testPosterDocumentDeduplicatesImageURLsAndQRCodeRenders() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://www.zhihu.com/pin/9"))
        let avatarURL = try XCTUnwrap(URL(string: "https://pic.example.com/avatar.jpg"))
        let imageURL = try XCTUnwrap(URL(string: "https://pic.example.com/a.jpg"))
        let document = NativeContentPosterDocument(
            title: "标题",
            authorName: "作者",
            authorAvatarURL: avatarURL,
            sourceURL: sourceURL,
            metadata: "1 赞 · 2 评论 · 想法",
            blocks: [
                .text("正文", style: .body),
                .image(imageURL, caption: nil),
                .image(imageURL, caption: "重复图片"),
            ]
        )

        XCTAssertEqual(document.imageURLs, [avatarURL, imageURL])
        XCTAssertNotNil(NativeContentPosterQRCode.image(for: sourceURL))
        XCTAssertNotNil(NativeContentPosterBranding.appIcon())
    }

    func testPosterRendererProducesCompleteLongImage() async throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://www.zhihu.com/answer/42"))
        let body = (1 ... 30).map { "第 \($0) 段完整正文" }.joined(separator: "\n")
        let document = NativeContentPosterDocument(
            title: "长回答",
            authorName: "作者",
            sourceURL: sourceURL,
            metadata: "10 赞同 · 2 评论 · 回答",
            blocks: [.text(body, style: .body)]
        )

        let image = try await NativeContentPosterRenderer.render(document)

        XCTAssertGreaterThan(image.size.height, image.size.width)
        XCTAssertEqual(image.size.width, 390, accuracy: 0.5)
    }
}

private final class NativeColumnRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func record(_ request: URLRequest) {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
    }
}

private final class NativeColumnURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])

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
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: ZhihuAPIError.invalidResponse)
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
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

private final class NativeColumnAccountStore: AccountJSONStore, @unchecked Sendable {
    private let lock = NSLock()
    private var json: String?

    init(json: String?) {
        self.json = json
    }

    func load() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return json
    }

    func save(_ accountJSON: String) throws {
        lock.lock()
        json = accountJSON
        lock.unlock()
    }

    func clear() throws {
        lock.lock()
        json = nil
        lock.unlock()
    }

    func update(_ transform: (String?) throws -> String?) throws {
        lock.lock()
        defer { lock.unlock() }
        json = try transform(json)
    }
}
