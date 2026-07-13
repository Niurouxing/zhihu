import Foundation
import XCTest
@testable import iosApp

@MainActor
final class PersonStoreTests: XCTestCase {
    func testStoreDefinesAllTenMainAndFourSubscriptionPages() throws {
        let store = makeStore(repository: PersonStoreRepository())

        XCTAssertEqual(PersonTab.allCases.count, 10)
        XCTAssertEqual(PersonSubscriptionTab.allCases.count, 4)
        XCTAssertEqual(store.pages.count, 14)
        XCTAssertEqual(store.selectedTab, .answers)
        XCTAssertEqual(store.selectedSubscriptionTab, .followingColumns)
        XCTAssertEqual(store.sortByTab[.answers], .voteups)
        XCTAssertEqual(store.sortByTab[.articles], .created)
    }

    func testInitialProfileAndPageCommitTypedState() async throws {
        let profile = fixtureProfile()
        let answer = answerItem(occurrence: 0)
        let repository = PersonStoreRepository(
            profiles: [.success(profile)],
            pages: [.main(.answers): [.success(.init(items: [answer], nextURL: nil, isEnd: true))]]
        )
        let store = makeStore(repository: repository)

        store.start()
        await waitUntil {
            if case .loaded = store.profileState,
               case .loaded = store.visiblePage.initialLoad {
                return true
            }
            return false
        }

        XCTAssertEqual(store.profile, profile)
        XCTAssertEqual(store.visiblePage.items, [answer])
        XCTAssertTrue(store.visiblePage.isEnd)
    }

    func testNextPageFailureKeepsExistingItemsAndCanRetry() async throws {
        let first = answerItem(occurrence: 0)
        let second = answerItem(occurrence: 0)
        let nextURL = URL(string: "https://www.zhihu.com/api/v4/next")!
        let repository = PersonStoreRepository(
            profiles: [.success(fixtureProfile())],
            pages: [
                .main(.answers): [
                    .success(.init(items: [first], nextURL: nextURL, isEnd: false)),
                    .failure(PersonStoreFailure.network),
                    .success(.init(items: [second], nextURL: nil, isEnd: true)),
                ],
            ]
        )
        let store = makeStore(repository: repository)
        store.start()
        await waitUntil { store.visiblePage.items.count == 1 }

        store.loadNextPageIfNeeded(after: first.id)
        await waitUntil {
            if case .failed = store.visiblePage.nextPage { return true }
            return false
        }
        XCTAssertEqual(store.visiblePage.items.count, 1)

        store.retryNextPage()
        await waitUntil { store.visiblePage.items.count == 2 }
        XCTAssertEqual(store.visiblePage.items.map(\.id.occurrence), [0, 1])
        XCTAssertTrue(store.visiblePage.isEnd)
    }

    func testConcurrentFollowAndBlockMergeIntoCurrentProfile() async throws {
        let repository = PersonStoreRepository(
            profiles: [.success(fixtureProfile())],
            pages: [.main(.answers): [.success(.init(items: [], nextURL: nil, isEnd: true))]],
            mutationYieldCount: 5
        )
        let store = makeStore(repository: repository)
        store.start()
        await waitUntil { store.profile != nil }

        store.toggleFollow()
        store.toggleBlock()
        XCTAssertTrue(store.followAction.isInFlight)
        XCTAssertTrue(store.blockAction.isInFlight)

        await waitUntil {
            store.profile?.isFollowing == true && store.profile?.isBlocking == true
        }
        let followRequests = await repository.followRequestCount()
        let blockRequests = await repository.blockRequestCount()
        XCTAssertEqual(followRequests, 1)
        XCTAssertEqual(blockRequests, 1)
    }

    func testSortChangeClearsOnlyItsAnchor() throws {
        let store = makeStore(repository: PersonStoreRepository())
        let answerAnchor = PersonListAnchor(
            firstVisibleItemID: answerItem(occurrence: 0).id,
            signedOffset: 18
        )
        let articleAnchor = PersonListAnchor(
            firstVisibleItemID: articleItem().id,
            signedOffset: -4
        )
        store.updateAnchor(answerAnchor, for: .main(.answers))
        store.updateAnchor(articleAnchor, for: .main(.articles))

        store.changeSort(.created)

        XCTAssertNil(store.anchors[.main(.answers)])
        XCTAssertEqual(store.anchors[.main(.articles)], articleAnchor)
        XCTAssertEqual(store.sortByTab[.answers], .created)
    }

    func testUnknownActivityHasNoVisibleNavigationEffect() throws {
        var intents: [PersonNavigationIntent] = []
        let store = makeStore(repository: PersonStoreRepository()) { intents.append($0) }
        let unknown = PersonPageItem.activity(
            PersonActivityItem(
                id: .init(kind: .activity, primaryID: "unknown", contextID: nil, occurrence: 0),
                title: "动态",
                summary: nil,
                details: "未知目标",
                destination: nil
            )
        )

        store.open(unknown)
        store.open(answerItem(occurrence: 0))

        XCTAssertEqual(intents, [.article(.init(id: 42, kind: .answer))])
    }

    private func makeStore(
        repository: PersonRepository,
        onNavigate: @escaping (PersonNavigationIntent) -> Void = { _ in }
    ) -> PersonStore {
        PersonStore(
            routeEntry: PersonRouteEntry(payload: fixtureRoute()),
            repository: repository,
            onNavigate: onNavigate
        )
    }

    private func fixtureRoute() -> PersonRoutePayload {
        PersonRoutePayload(
            memberID: "member-id",
            urlToken: "author-token",
            displayName: "作者"
        )!
    }

    private func fixtureProfile() -> PersonProfile {
        PersonProfile(
            memberID: "member-id",
            urlToken: "author-token",
            displayName: "作者",
            avatarURL: nil,
            headline: "简介",
            primaryOfficialBadge: nil,
            officialBadgeDetails: [],
            followerCount: 10,
            followingCount: 20,
            answerCount: 30,
            articleCount: 40,
            isFollowing: false,
            isBlocking: false,
            memberScopedSearchID: "member-id"
        )
    }

    private func answerItem(occurrence: Int) -> PersonPageItem {
        .answer(
            PersonAnswerItem(
                id: .init(kind: .answer, primaryID: "42", contextID: "7", occurrence: occurrence),
                answerID: 42,
                questionID: 7,
                questionTitle: "问题",
                excerpt: "回答摘要",
                voteUpCount: 1,
                commentCount: 2
            )
        )
    }

    private func articleItem() -> PersonPageItem {
        .article(
            PersonArticleItem(
                id: .init(kind: .article, primaryID: "8", contextID: nil, occurrence: 0),
                articleID: 8,
                title: "文章",
                excerpt: "摘要",
                voteUpCount: 3,
                commentCount: 4
            )
        )
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied", file: file, line: line)
    }
}

private enum PersonStoreFailure: LocalizedError {
    case missingStub
    case network

    var errorDescription: String? {
        switch self {
        case .missingStub: return "缺少测试响应"
        case .network: return "网络失败"
        }
    }
}

private actor PersonStoreRepository: PersonRepository {
    private var profiles: [Result<PersonProfile, Error>]
    private var pages: [PersonPageKey: [Result<PersonPageResult, Error>]]
    private let mutationYieldCount: Int
    private var followRequests = 0
    private var blockRequests = 0

    init(
        profiles: [Result<PersonProfile, Error>] = [],
        pages: [PersonPageKey: [Result<PersonPageResult, Error>]] = [:],
        mutationYieldCount: Int = 0
    ) {
        self.profiles = profiles
        self.pages = pages
        self.mutationYieldCount = mutationYieldCount
    }

    func fetchProfile(
        identity: PersonIdentity,
        provisionalDisplayName: String
    ) async throws -> PersonProfile {
        guard !profiles.isEmpty else { throw PersonStoreFailure.missingStub }
        return try profiles.removeFirst().get()
    }

    func fetchPage(
        key: PersonPageKey,
        identity: PersonIdentity,
        sort: PersonContentSort?,
        nextURL: URL?
    ) async throws -> PersonPageResult {
        guard var results = pages[key], !results.isEmpty else {
            throw PersonStoreFailure.missingStub
        }
        let result = results.removeFirst()
        pages[key] = results
        return try result.get()
    }

    func setFollowing(_ target: Bool, profile: PersonProfile) async throws -> PersonFollowResult {
        followRequests += 1
        for _ in 0..<mutationYieldCount {
            await Task.yield()
        }
        return PersonFollowResult(
            isFollowing: target,
            followerCount: profile.followerCount + (target ? 1 : -1)
        )
    }

    func setBlocking(_ target: Bool, profile: PersonProfile) async throws {
        blockRequests += 1
        for _ in 0..<mutationYieldCount {
            await Task.yield()
        }
    }

    func followRequestCount() -> Int { followRequests }
    func blockRequestCount() -> Int { blockRequests }
}
