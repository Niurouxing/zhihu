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
        XCTAssertNil(NativeContentDestinationResolver.resolve("file:///private/secret"))
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
}
