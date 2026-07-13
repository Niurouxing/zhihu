import CoreGraphics
import Foundation

struct PersonListAnchor: Hashable {
    let firstVisibleItemID: PersonListItemID
    let signedOffset: CGFloat
}

@MainActor
final class PersonStore: ObservableObject {
    let routeEntry: PersonRouteEntry

    @Published private(set) var profileState: PersonProfileLoadState
    @Published private(set) var followAction: PersonActionState = .idle
    @Published private(set) var blockAction: PersonActionState = .idle
    @Published private(set) var pages: [PersonPageKey: PersonPageState]
    @Published var selectedTab: PersonTab
    @Published var selectedSubscriptionTab: PersonSubscriptionTab = .followingColumns
    @Published private(set) var sortByTab: [PersonTab: PersonContentSort] = [
        .answers: .voteups,
        .articles: .created,
    ]
    private(set) var anchors: [PersonPageKey: PersonListAnchor] = [:]

    private let repository: PersonRepository
    private let onNavigate: (PersonNavigationIntent) -> Void
    private var profileGeneration: UInt64 = 0
    private var pageGenerations: [PersonPageKey: UInt64] = [:]
    private var profileTask: Task<Void, Never>?
    private var pageTasks: [PersonPageKey: Task<Void, Never>] = [:]
    private var followTask: Task<Void, Never>?
    private var blockTask: Task<Void, Never>?
    private var isDisposed = false

    init(
        routeEntry: PersonRouteEntry,
        repository: PersonRepository,
        onNavigate: @escaping (PersonNavigationIntent) -> Void
    ) {
        self.routeEntry = routeEntry
        self.repository = repository
        self.onNavigate = onNavigate
        selectedTab = routeEntry.payload.initialTab
        profileState = .idle(provisionalDisplayName: routeEntry.payload.displayName)
        pages = Dictionary(uniqueKeysWithValues: PersonTab.allCases.map { (.main($0), PersonPageState()) })
        for tab in PersonSubscriptionTab.allCases {
            pages[.subscription(tab)] = PersonPageState()
        }
    }

    var profile: PersonProfile? { profileState.profile }

    var navigationTitle: String {
        profile?.displayName.nonBlank ?? routeEntry.payload.displayName.nonBlank ?? "用户主页"
    }

    var visiblePageKey: PersonPageKey {
        selectedTab == .subscriptions ? .subscription(selectedSubscriptionTab) : .main(selectedTab)
    }

    var visiblePage: PersonPageState {
        pages[visiblePageKey] ?? PersonPageState()
    }

    func start() {
        guard !isDisposed else { return }
        if case .idle = profileState { loadProfile() }
        ensureVisiblePageLoaded()
    }

    func selectTab(_ tab: PersonTab) {
        selectedTab = tab
        ensureVisiblePageLoaded()
    }

    func selectSubscriptionTab(_ tab: PersonSubscriptionTab) {
        selectedSubscriptionTab = tab
        if selectedTab == .subscriptions { ensureVisiblePageLoaded() }
    }

    func changeSort(_ sort: PersonContentSort) {
        guard selectedTab == .answers || selectedTab == .articles,
              sortByTab[selectedTab] != sort
        else { return }
        sortByTab[selectedTab] = sort
        let key = PersonPageKey.main(selectedTab)
        anchors[key] = nil
        refresh(key)
    }

    func refreshVisiblePage() async {
        refresh(visiblePageKey)
        await pageTasks[visiblePageKey]?.value
    }

    func retryProfile() {
        loadProfile()
    }

    func retryInitialPage() {
        refresh(visiblePageKey)
    }

    func retryNextPage() {
        loadNextPage(visiblePageKey)
    }

    func loadNextPageIfNeeded(after itemID: PersonListItemID) {
        let page = visiblePage
        guard page.items.suffix(3).contains(where: { $0.id == itemID }) else { return }
        loadNextPage(visiblePageKey)
    }

    func toggleFollow() {
        guard !followAction.isInFlight, let profile else { return }
        followTask?.cancel()
        followAction = .inFlight
        let target = !profile.isFollowing
        let generation = profileGeneration
        followTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await repository.setFollowing(target, profile: profile)
                guard acceptsProfile(generation), let current = self.profile else { return }
                let updated = current.replacingFollowState(result.isFollowing, followerCount: result.followerCount)
                profileState = .loaded(updated)
                followAction = .idle
            } catch is CancellationError {
                return
            } catch {
                guard acceptsProfile(generation) else { return }
                followAction = .failed(displayError(error))
            }
        }
    }

    func retryFollow() {
        guard case .failed = followAction else { return }
        toggleFollow()
    }

    func toggleBlock() {
        guard !blockAction.isInFlight, let profile else { return }
        blockTask?.cancel()
        blockAction = .inFlight
        let target = !profile.isBlocking
        let generation = profileGeneration
        blockTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await repository.setBlocking(target, profile: profile)
                guard acceptsProfile(generation), let current = self.profile else { return }
                profileState = .loaded(current.replacingBlockState(target))
                blockAction = .idle
            } catch is CancellationError {
                return
            } catch {
                guard acceptsProfile(generation) else { return }
                blockAction = .failed(displayError(error))
            }
        }
    }

    func retryBlock() {
        guard case .failed = blockAction else { return }
        toggleBlock()
    }

    func open(_ item: PersonPageItem) {
        guard let intent = navigationIntent(for: item) else { return }
        onNavigate(intent)
    }

    func openProfileInWeb() {
        guard let profile,
              let identifier = profile.urlToken?.nonBlank ?? profile.memberID.nonBlank,
              let url = URL(string: "https://www.zhihu.com/people/\(pathSegment(identifier))"),
              let route = PersonWebRoute(kind: .profile, title: profile.displayName, url: url)
        else { return }
        onNavigate(.web(route))
    }

    func openMemberSearch() {
        guard let profile,
              let searchID = profile.memberScopedSearchID?.nonBlank,
              var components = URLComponents(string: "https://www.zhihu.com/search")
        else { return }
        components.queryItems = [
            URLQueryItem(name: "type", value: "content"),
            URLQueryItem(name: "restricted_scene", value: "member"),
            URLQueryItem(name: "restricted_field", value: "member_hash_id"),
            URLQueryItem(name: "restricted_value", value: searchID),
        ]
        guard let url = components.url,
              let route = PersonWebRoute(kind: .search, title: "搜索 \(profile.displayName) 的创作", url: url)
        else { return }
        onNavigate(.web(route))
    }

    func updateAnchor(_ anchor: PersonListAnchor?, for key: PersonPageKey) {
        anchors[key] = anchor
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        profileGeneration &+= 1
        profileTask?.cancel()
        pageTasks.values.forEach { $0.cancel() }
        followTask?.cancel()
        blockTask?.cancel()
        pageTasks.removeAll()
    }

    private func loadProfile() {
        guard !isDisposed else { return }
        profileTask?.cancel()
        followTask?.cancel()
        blockTask?.cancel()
        profileGeneration &+= 1
        let generation = profileGeneration
        let previous = profile
        profileState = .loading(previous: previous)
        followAction = .idle
        blockAction = .idle
        let identity = PersonIdentity(route: routeEntry.payload, profile: previous)
        profileTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await repository.fetchProfile(
                    identity: identity,
                    provisionalDisplayName: routeEntry.payload.displayName
                )
                guard acceptsProfile(generation) else { return }
                profileState = .loaded(loaded)
                ensureVisiblePageLoaded()
            } catch is CancellationError {
                return
            } catch {
                guard acceptsProfile(generation) else { return }
                profileState = .failed(error: displayError(error), previous: previous)
            }
        }
    }

    private func ensureVisiblePageLoaded() {
        let key = visiblePageKey
        if case .main(.followers) = key,
           PersonIdentity(route: routeEntry.payload, profile: profile).memberID?.nonBlank == nil {
            return
        }
        guard let page = pages[key], case .idle = page.initialLoad else { return }
        loadInitialPage(key, preserveItems: false)
    }

    private func refresh(_ key: PersonPageKey) {
        loadInitialPage(key, preserveItems: true)
    }

    private func loadInitialPage(_ key: PersonPageKey, preserveItems: Bool) {
        guard !isDisposed else { return }
        pageTasks[key]?.cancel()
        let generation = nextPageGeneration(key)
        var page = pages[key] ?? PersonPageState()
        let previousItems = preserveItems ? page.items : []
        page.initialLoad = .loading
        page.nextPage = .idle
        page.isEnd = false
        page.nextURL = nil
        if !preserveItems { page.items = [] }
        pages[key] = page
        let identity = PersonIdentity(route: routeEntry.payload, profile: profile)
        let sort = sort(for: key)
        pageTasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await repository.fetchPage(key: key, identity: identity, sort: sort, nextURL: nil)
                guard acceptsPage(key, generation) else { return }
                var loaded = PersonPageState()
                loaded.initialLoad = .loaded
                loaded.items = normalizeOccurrences(result.items, existing: [])
                loaded.nextURL = result.nextURL
                loaded.isEnd = result.isEnd
                pages[key] = loaded
            } catch is CancellationError {
                return
            } catch {
                guard acceptsPage(key, generation) else { return }
                var failed = pages[key] ?? PersonPageState()
                failed.initialLoad = .failed(displayError(error))
                failed.items = previousItems
                pages[key] = failed
            }
        }
    }

    private func loadNextPage(_ key: PersonPageKey) {
        guard !isDisposed, var page = pages[key], page.canLoadNext, let nextURL = page.nextURL else { return }
        let generation = pageGenerations[key, default: 0]
        page.nextPage = .loading
        pages[key] = page
        let identity = PersonIdentity(route: routeEntry.payload, profile: profile)
        let sort = sort(for: key)
        pageTasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await repository.fetchPage(key: key, identity: identity, sort: sort, nextURL: nextURL)
                guard acceptsPage(key, generation), var current = pages[key] else { return }
                current.items.append(contentsOf: normalizeOccurrences(result.items, existing: current.items))
                current.nextURL = result.nextURL
                current.isEnd = result.isEnd
                current.nextPage = .idle
                pages[key] = current
            } catch is CancellationError {
                return
            } catch {
                guard acceptsPage(key, generation), var current = pages[key] else { return }
                current.nextPage = .failed(displayError(error))
                pages[key] = current
            }
        }
    }

    private func sort(for key: PersonPageKey) -> PersonContentSort? {
        guard case let .main(tab) = key else { return nil }
        return sortByTab[tab]
    }

    private func nextPageGeneration(_ key: PersonPageKey) -> UInt64 {
        let value = pageGenerations[key, default: 0] &+ 1
        pageGenerations[key] = value
        return value
    }

    private func acceptsProfile(_ generation: UInt64) -> Bool {
        !isDisposed && generation == profileGeneration
    }

    private func acceptsPage(_ key: PersonPageKey, _ generation: UInt64) -> Bool {
        !isDisposed && pageGenerations[key] == generation
    }

    private func navigationIntent(for item: PersonPageItem) -> PersonNavigationIntent? {
        switch item {
        case let .answer(value):
            return .article(PersonArticleRoute(id: value.answerID, kind: .answer))
        case let .article(value):
            return .article(PersonArticleRoute(id: value.articleID, kind: .article))
        case let .activity(value):
            return value.destination
        case let .collection(value):
            return webIntent(.collection, value.title, "https://www.zhihu.com/collection/\(pathSegment(value.collectionID))")
        case let .question(value):
            return webIntent(.question, value.title, "https://www.zhihu.com/question/\(value.questionID)")
        case let .pin(value):
            return webIntent(.pin, "想法", "https://www.zhihu.com/pin/\(value.pinID)")
        case let .column(value):
            return value.destination.map(PersonNavigationIntent.web)
        case let .person(value):
            return .person(value.route)
        case let .topic(value):
            return value.destination.map(PersonNavigationIntent.web)
        case let .followedQuestion(value):
            guard let questionID = value.questionID else { return nil }
            return webIntent(.question, value.title, "https://www.zhihu.com/question/\(questionID)")
        }
    }

    private func webIntent(_ kind: PersonWebRouteKind, _ title: String, _ value: String) -> PersonNavigationIntent? {
        guard let url = URL(string: value), let route = PersonWebRoute(kind: kind, title: title, url: url) else { return nil }
        return .web(route)
    }

    private func normalizeOccurrences(
        _ items: [PersonPageItem],
        existing: [PersonPageItem]
    ) -> [PersonPageItem] {
        struct Base: Hashable {
            let kind: PersonListItemID.Kind
            let primaryID: String
            let contextID: String?
        }
        var counts: [Base: Int] = [:]
        for item in existing {
            let base = Base(kind: item.id.kind, primaryID: item.id.primaryID, contextID: item.id.contextID)
            counts[base] = max(counts[base, default: 0], item.id.occurrence + 1)
        }
        return items.map { item in
            let base = Base(kind: item.id.kind, primaryID: item.id.primaryID, contextID: item.id.contextID)
            let occurrence = counts[base, default: 0]
            counts[base] = occurrence + 1
            return item.replacingID(
                PersonListItemID(
                    kind: item.id.kind,
                    primaryID: item.id.primaryID,
                    contextID: item.id.contextID,
                    occurrence: occurrence
                )
            )
        }
    }

    private func displayError(_ error: Error) -> PersonDisplayError {
        PersonDisplayError(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private func pathSegment(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
