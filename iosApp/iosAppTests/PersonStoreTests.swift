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

    func testFollowerStatisticsPushConnectionPagesWithoutReplacingSelectedContentTab() throws {
        var intents: [PersonNavigationIntent] = []
        let store = makeStore(repository: PersonStoreRepository()) { intents.append($0) }

        store.selectTab(.followers)
        store.selectTab(.following)

        XCTAssertEqual(store.selectedTab, .answers)
        XCTAssertEqual(intents.count, 2)
        guard case let .connections(followers) = intents[0],
              case let .connections(following) = intents[1]
        else { return XCTFail("Expected connection-list navigation intents") }
        XCTAssertEqual(followers.person.initialTab, .followers)
        XCTAssertEqual(following.person.initialTab, .following)
        XCTAssertEqual(followers.person.memberID, "member-id")
        XCTAssertEqual(following.person.urlToken, "author-token")
    }

    func testMemberSearchUsesNativeRestrictedSearchRoute() async throws {
        let repository = PersonStoreRepository(
            profiles: [.success(fixtureProfile())],
            pages: [.main(.answers): [.success(.init(items: [], nextURL: nil, isEnd: true))]]
        )
        var intents: [PersonNavigationIntent] = []
        let store = makeStore(repository: repository) { intents.append($0) }
        store.start()
        await waitUntil { store.profile != nil }

        store.openMemberSearch()

        guard case let .search(route) = intents.last else {
            return XCTFail("Expected native restricted search route")
        }
        XCTAssertEqual(route.restrictedMemberHashID, "member-id")
        XCTAssertEqual(route.restrictedMemberName, "作者")
        XCTAssertEqual(route.query, "")
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

    func testEveryNavigablePersonPageItemEmitsItsTypedIntent() throws {
        let columnRoute = try XCTUnwrap(PersonWebRoute(
            kind: .column,
            title: "专栏",
            url: URL(string: "https://www.zhihu.com/column/column-id")!
        ))
        let topicRoute = try XCTUnwrap(PersonWebRoute(
            kind: .topic,
            title: "话题",
            url: URL(string: "https://www.zhihu.com/topic/15")!
        ))
        let personRoute = try XCTUnwrap(PersonRoutePayload(
            memberID: "next-member",
            urlToken: "next-person",
            displayName: "另一个用户"
        ))
        let items: [PersonPageItem] = [
            answerItem(occurrence: 0),
            articleItem(),
            .activity(.init(
                id: itemID(.activity, "activity"),
                title: "动态",
                summary: nil,
                details: "关注了问题",
                destination: .question(9)
            )),
            .collection(.init(
                id: itemID(.collection, "collection-id"),
                collectionID: "collection-id",
                title: "收藏夹",
                contentCount: 1,
                followerCount: 2
            )),
            .question(.init(
                id: itemID(.question, "10"),
                questionID: 10,
                title: "问题",
                answerCount: 3,
                followerCount: 4
            )),
            .pin(.init(
                id: itemID(.pin, "11"),
                pinID: 11,
                excerptPlainText: "想法",
                likeCount: 5,
                commentCount: 6
            )),
            .column(.init(
                id: itemID(.column, "column-id"),
                columnID: "column-id",
                title: "专栏",
                description: nil,
                articleCount: 7,
                followerCount: 8,
                destination: columnRoute
            )),
            .person(.init(
                id: itemID(.person, "next-member"),
                route: personRoute,
                avatarURL: nil,
                headline: "简介",
                primaryOfficialBadge: nil,
                answerCount: 9,
                articleCount: 10,
                followerCount: 11
            )),
            .topic(.init(
                id: itemID(.topic, "15"),
                topicID: "15",
                displayName: "话题",
                avatarURL: nil,
                destination: topicRoute
            )),
            .followedQuestion(.init(
                id: itemID(.followedQuestion, "12"),
                rawQuestionID: "12",
                title: "关注的问题",
                questionID: 12
            )),
        ]
        var intents: [PersonNavigationIntent] = []
        let store = makeStore(repository: PersonStoreRepository()) { intents.append($0) }

        items.forEach(store.open)

        XCTAssertEqual(intents, [
            .article(.init(id: 42, kind: .answer)),
            .article(.init(id: 8, kind: .article)),
            .question(9),
            .collection("collection-id"),
            .question(10),
            .pin(11),
            .web(columnRoute),
            .person(personRoute),
            .web(topicRoute),
            .question(12),
        ])
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

    private func itemID(_ kind: PersonListItemID.Kind, _ primaryID: String) -> PersonListItemID {
        PersonListItemID(kind: kind, primaryID: primaryID, contextID: nil, occurrence: 0)
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
