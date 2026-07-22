import CoreSpotlight
import SwiftUI
import UIKit

enum NativeShellRoute: Hashable {
    case answer(AnswerRouteDTO)
    case question(QuestionRouteDTO)
    case person(PersonRoutePayload)
    case personWeb(PersonWebRoute)
    case pin(PinRouteDTO)
    case search(SearchRouteDTO)
    case hotList
    case writeAnswer(WriteAnswerRouteDTO)
    case writePin
    case account
    case collections(userToken: String)
    case collectionContent(String)
    case history
    case notifications
    case notificationSettings
    case settings
    case systemAndUpdate
}

extension PersonNavigationIntent {
    var nativeShellRoute: NativeShellRoute {
        switch self {
        case let .article(route):
            return .answer(.init(contentID: route.id, kind: route.kind == .answer ? .answer : .article))
        case let .question(id): return .question(.init(questionID: id))
        case let .pin(id): return .pin(.init(pinID: id))
        case let .collection(id): return .collectionContent(id)
        case let .person(payload): return .person(payload)
        case let .web(route): return .personWeb(route)
        }
    }
}

@MainActor
final class NativeTabNavigationState: ObservableObject {
    @Published private var paths: [NativeAppTab: [NativeShellRoute]] = [:]

    func binding(for tab: NativeAppTab) -> Binding<[NativeShellRoute]> {
        Binding(get: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
    }

    func navigate(to route: NativeShellRoute, in tab: NativeAppTab) {
        var path = paths[tab] ?? []
        if path.last != route { path.append(route) }
        paths[tab] = path
    }

    func replaceTop(with route: NativeShellRoute, in tab: NativeAppTab) {
        var path = paths[tab] ?? []
        if !path.isEmpty { path.removeLast() }
        path.append(route)
        paths[tab] = path
    }

    func isAtRoot(in tab: NativeAppTab) -> Bool {
        paths[tab, default: []].isEmpty
    }

    func resetAll() { paths.removeAll() }
}

private struct NativeCommentPresentation: Identifiable, Hashable {
    let id = UUID()
    let route: CommentThreadRouteDTO
}

private struct NativeMediaPresentation: Identifiable, Hashable {
    let id = UUID()
    let urls: [URL]
    let initialIndex: Int
}

@available(iOS 16.0, *)
struct NativeAppShell: View {
    let hostModel: HostModel
    @ObservedObject private var preferences: NativeShellPreferences
    @ObservedObject private var account: NativeAccountStore
    @ObservedObject private var notifications: NativeNotificationStore
    @ObservedObject private var notificationPreferences: NativeNotificationPreferences

    @StateObject private var navigation = NativeTabNavigationState()
    @State private var selectedTab: NativeAppTab
    @State private var commentPresentation: NativeCommentPresentation?
    @State private var mediaPresentation: NativeMediaPresentation?
    @State private var shareURL: URL?
    @State private var pendingShareChoiceURL: URL?
    @State private var showsCopiedLinkConfirmation = false

    init(hostModel: HostModel) {
        self.hostModel = hostModel
        _preferences = ObservedObject(wrappedValue: hostModel.preferences)
        _account = ObservedObject(wrappedValue: hostModel.account)
        _notifications = ObservedObject(wrappedValue: hostModel.notifications)
        _notificationPreferences = ObservedObject(wrappedValue: hostModel.notificationPreferences)
        _selectedTab = State(initialValue: hostModel.preferences.startTab)
    }

    var body: some View {
        tabBarBehavior(
            TabView(selection: $selectedTab) {
                ForEach(preferences.selectedTabs) { tab in
                    NavigationStack(path: navigation.binding(for: tab)) {
                        rootContent(for: tab)
                            .navigationDestination(for: NativeShellRoute.self) { destination($0, in: tab) }
                    }
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
                }
            }
        )
        .background(
            NativeTabReselectObserver(
                isEnabled: preferences.topLevelReselectEnabled,
                tabs: preferences.selectedTabs,
                selectedTab: selectedTab
            )
            .frame(width: 0, height: 0)
        )
        .preferredColorScheme(preferences.themeMode.colorScheme)
        .sheet(item: $commentPresentation) { presentation in
            NativeCommentRouteView(
                route: presentation.route,
                accountStore: hostModel.accountStore,
                onPersonNavigate: handleCommentPersonIntent
            )
        }
        .sheet(item: Binding(
            get: { shareURL.map(NativeSharePresentation.init) },
            set: { if $0 == nil { shareURL = nil } }
        )) { presentation in
            NativeShareSheet(items: [presentation.url])
        }
        .confirmationDialog(
            "分享链接",
            isPresented: Binding(
                get: { pendingShareChoiceURL != nil },
                set: { if !$0 { pendingShareChoiceURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("系统分享") {
                shareURL = pendingShareChoiceURL
                pendingShareChoiceURL = nil
            }
            Button("复制链接") {
                guard let url = pendingShareChoiceURL else { return }
                pendingShareChoiceURL = nil
                copyShareURL(url)
            }
            Button("取消", role: .cancel) { pendingShareChoiceURL = nil }
        }
        .alert("链接已复制", isPresented: $showsCopiedLinkConfirmation) {
            Button("好", role: .cancel) {}
        }
        .fullScreenCover(item: $mediaPresentation) { presentation in
            NativeMediaGallery(urls: presentation.urls, initialIndex: presentation.initialIndex)
        }
        .onChange(of: preferences.selectedTabs) { tabs in
            if !tabs.contains(selectedTab) { selectedTab = preferences.startTab }
        }
        .onChange(of: account.identity.map { "\($0.id)|\($0.urlToken ?? "")" }) { _ in
            navigation.resetAll()
            Task { await notifications.refreshUnreadCounts() }
        }
        .task {
            if case .loading = account.state { account.reloadFromKeychain() }
            if account.isSignedIn { await notifications.refreshUnreadCounts() }
            SystemNavigationRequestCenter.shared.installHandler(handleSystemNavigation)
        }
        .onDisappear { SystemNavigationRequestCenter.shared.removeHandler() }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let route = SpotlightRouteCodec.route(fromSearchableItemIdentifier: identifier)
            else { return }
            openContent(route.nativeDestination)
        }
        .environment(\.nativeContentPresentation, preferences.contentPresentation)
        .environment(\.nativeSearchPresentation, preferences.searchPresentation)
    }

    @ViewBuilder
    private func rootContent(for tab: NativeAppTab) -> some View {
        switch tab {
        case .home:
            HomeNativeView(
                repository: hostModel.homeRepository,
                header: HomeHeaderDTO(
                    displayName: account.identity?.name ?? "账号",
                    avatarURL: account.identity?.avatarURL,
                    unreadCount: notifications.unreadCount
                ),
                onOpen: openFeed,
                onEntry: handleHomeEntry
            )
        case .follow:
            FollowNativeView(
                repository: hostModel.followRepository,
                onOpen: openFeed,
                onOpenPerson: { navigate(.person($0)) }
            )
        case .hot:
            HotListNativeView(repository: hostModel.hotRepository, onOpen: openFeed)
        case .daily:
            DailyNativeView(repository: hostModel.dailyRepository, onOpen: handleDailyDestination)
        case .history:
            if account.isSignedIn {
                NativeHistoryView(repository: hostModel.libraryRepository, onOpenContent: openContent)
            } else {
                NativeSignedOutLibraryView(title: "登录后查看浏览历史", openLogin: hostModel.openLogin)
            }
        case .collections:
            if let token = account.identity?.collectionToken {
                NativeCollectionsView(
                    userToken: token,
                    repository: hostModel.libraryRepository,
                    onOpenContent: openContent
                )
            } else {
                NativeSignedOutLibraryView(title: "登录后查看收藏夹", openLogin: hostModel.openLogin)
            }
        case .account:
            NativeAccountView(store: account, actions: accountActions)
        }
    }

    @ViewBuilder
    private func destination(_ route: NativeShellRoute, in tab: NativeAppTab) -> some View {
        Group {
            switch route {
            case let .answer(route):
                ArticleHostView(
                    route: route,
                    repository: hostModel.questionAnswerRepository,
                    openedHistory: hostModel.answerOpenedHistory,
                    onNavigate: handleQAIntent
                )
        case let .question(route):
            NativeQuestionRouteView(
                route: route,
                repository: hostModel.questionAnswerRepository,
                onNavigate: handleQAIntent
            )
        case let .person(payload):
            NativePersonRouteView(
                payload: payload,
                accountStore: hostModel.accountStore,
                onNavigate: { handlePersonIntent($0, in: tab) }
            )
        case let .personWeb(route):
            PersonWebDestinationView(route: route, accountStore: hostModel.accountStore)
        case let .pin(route):
            PinNativeView(
                route: route,
                repository: hostModel.pinRepository,
                onOpenPerson: { navigate(.person($0), in: tab) },
                onOpenLink: handlePinLink,
                onOpenComments: { commentPresentation = .init(route: .init(subject: .pin($0))) }
            )
        case let .search(route):
            SearchNativeView(route: route, repository: hostModel.searchRepository, onOpen: openFeed)
        case .hotList:
            HotListNativeView(repository: hostModel.hotRepository, onOpen: openFeed)
        case let .writeAnswer(route):
            WriteAnswerNativeView(
                route: route,
                repository: hostModel.creationRepository,
                onSystemIntent: handleCreationIntent,
                onPublished: { navigation.replaceTop(with: .answer(.init(
                    contentID: $0,
                    kind: .answer,
                    questionID: route.questionID,
                    provisionalTitle: route.questionTitle
                )), in: tab) }
            )
        case .writePin:
            WritePinNativeView(
                repository: hostModel.creationRepository,
                onSystemIntent: handleCreationIntent,
                onPublished: { navigation.replaceTop(with: .pin(.init(pinID: $0)), in: tab) }
            )
        case .account:
            NativeAccountView(store: account, actions: accountActions)
        case let .collections(token):
            NativeCollectionsView(userToken: token, repository: hostModel.libraryRepository, onOpenContent: openContent)
        case let .collectionContent(id):
            NativeCollectionContentView(collectionID: id, repository: hostModel.libraryRepository, onOpenContent: openContent)
        case .history:
            NativeHistoryView(repository: hostModel.libraryRepository, onOpenContent: openContent)
        case .notifications:
            NativeNotificationsView(store: notifications, preferences: notificationPreferences, onOpenContent: openContent)
        case .notificationSettings:
            NativeNotificationSettingsView(preferences: notificationPreferences)
        case .settings:
            NativeSettingsView(
                preferences: preferences,
                notificationPreferences: notificationPreferences,
                systemSettings: hostModel.systemSettings,
                appLock: hostModel.appLock,
                setAppLock: hostModel.setAppLock
            )
            case .systemAndUpdate:
                SystemAndUpdateView(openExternalLink: hostModel.openSystemExternalLink)
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }

    private var accountActions: NativeAccountActions {
        NativeAccountActions(
            openLogin: hostModel.openLogin,
            openQrAuthorization: hostModel.openQrAuthorization,
            openProfile: { identity in
                guard let payload = PersonRoutePayload(
                    memberID: identity.id,
                    urlToken: identity.urlToken,
                    displayName: identity.name,
                    initialTab: .activities
                ) else { return }
                navigate(.person(payload))
            }
        )
    }

    private func navigate(_ route: NativeShellRoute, in tab: NativeAppTab? = nil) {
        navigation.navigate(to: route, in: tab ?? selectedTab)
    }

    private func handleHomeEntry(_ intent: HomeEntryIntent) {
        switch intent {
        case .search: navigate(.search(.init()))
        case .profile:
            guard let identity = account.identity else {
                hostModel.openLogin()
                return
            }
            accountActions.openProfile(identity)
        case .account: navigate(.account)
        case .notifications: navigate(.notifications)
        case .create: navigate(.writePin)
        }
    }

    private func openFeed(_ route: FeedItemRoute) {
        switch route {
        case let .answer(id, questionID, title):
            navigate(.answer(.init(contentID: id, kind: .answer, questionID: questionID, provisionalTitle: title)))
        case let .article(id, title):
            navigate(.answer(.init(contentID: id, kind: .article, provisionalTitle: title)))
        case let .question(id, title):
            navigate(.question(.init(questionID: id, provisionalTitle: title)))
        case let .pin(id):
            navigate(.pin(.init(pinID: id)))
        case let .video(id):
            openVideoPage(URL(string: "https://www.zhihu.com/zvideo/\(id)")!)
        }
    }

    private func openContent(_ destination: NativeContentDestination) {
        switch destination {
        case let .article(id, kind):
            navigate(.answer(.init(contentID: id, kind: kind == .answer ? .answer : .article)))
        case let .question(id): navigate(.question(.init(questionID: id)))
        case let .person(id, token, name):
            if let payload = PersonRoutePayload(memberID: id, urlToken: token, displayName: name) {
                navigate(.person(payload))
            }
        case let .pin(id): navigate(.pin(.init(pinID: id)))
        case let .search(query): navigate(.search(.init(query: query)))
        case let .external(url): hostModel.openExternal(url)
        }
    }

    private func handleDailyDestination(_ destination: DailyStoryDestination) {
        switch destination {
        case let .feed(route): openFeed(route)
        case let .external(url): hostModel.openExternal(url)
        }
    }

    private func handlePinLink(_ destination: PinLinkDestination) {
        switch destination {
        case let .feed(route): openFeed(route)
        case let .external(url): hostModel.openExternal(url)
        }
    }

    private func handleQAIntent(_ intent: QANavigationIntent) {
        switch intent {
        case let .person(payload): navigate(.person(payload))
        case let .question(route): navigate(.question(route))
        case let .answer(route): navigate(.answer(route))
        case let .writeAnswer(route): navigate(.writeAnswer(route))
        case let .comments(route), let .segmentComments(route):
            commentPresentation = .init(route: route)
        case let .images(urls, index):
            guard !urls.isEmpty else { return }
            mediaPresentation = .init(urls: urls, initialIndex: index)
        case let .link(link): handleQALink(link)
        case let .endorsement(url):
            if let destination = NativeContentDestinationResolver.resolve(url.absoluteString) {
                openContent(destination)
            } else {
                hostModel.openExternal(url)
            }
        case let .videoPage(url): openVideoPage(url)
        case let .share(url): handleShare(url)
        }
    }

    private func openVideoPage(_ url: URL) {
        guard let route = PersonWebRoute(kind: .video, title: "视频", url: url) else { return }
        navigate(.personWeb(route))
    }

    private func handleShare(_ url: URL) {
        switch preferences.defaultShareAction {
        case .ask:
            pendingShareChoiceURL = url
        case .systemShare:
            shareURL = url
        case .copyLink:
            copyShareURL(url)
        }
    }

    private func copyShareURL(_ url: URL) {
        UIPasteboard.general.url = url
        showsCopiedLinkConfirmation = true
    }

    private func handleQALink(_ link: QALinkDestination) {
        switch link {
        case let .answer(id): navigate(.answer(.init(contentID: id, kind: .answer)))
        case let .article(id): navigate(.answer(.init(contentID: id, kind: .article)))
        case let .question(id): navigate(.question(.init(questionID: id)))
        case let .person(token):
            if let payload = PersonRoutePayload(memberID: nil, urlToken: token, displayName: "") {
                navigate(.person(payload))
            }
        case let .external(url): hostModel.openExternal(url)
        }
    }

    private func handlePersonIntent(_ intent: PersonNavigationIntent, in tab: NativeAppTab) {
        navigate(intent.nativeShellRoute, in: tab)
    }

    private func handleCommentPersonIntent(_ intent: PersonNavigationIntent) {
        let tab = selectedTab
        commentPresentation = nil
        DispatchQueue.main.async { handlePersonIntent(intent, in: tab) }
    }

    private func handleCreationIntent(_ intent: CreationSystemIntent, retry: @escaping () async -> Void) {
        switch intent {
        case .loginRequired: hostModel.openLogin()
        case let .riskControlRequired(url): hostModel.openRiskControl(url: url, retry: retry)
        }
    }

    private func handleSystemNavigation(_ envelope: SystemNavigationRequestEnvelope) {
        switch envelope.request {
        case let .search(query):
            navigate(.search(.init(query: query ?? "")))
        case .hot:
            if preferences.selectedTabs.contains(.hot) { selectedTab = .hot } else { navigate(.hotList) }
        case .collections:
            guard let token = account.identity?.collectionToken else {
                hostModel.openLogin()
                return
            }
            navigate(.collections(userToken: token))
        }
    }

    @ViewBuilder
    private func tabBarBehavior<Content: View>(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(preferences.autoHideTabBar ? .onScrollDown : .never)
        } else { content }
    }
}

private struct NativeTabReselectObserver: UIViewRepresentable {
    let isEnabled: Bool
    let tabs: [NativeAppTab]
    let selectedTab: NativeAppTab

    func makeUIView(context: Context) -> InstallerView {
        InstallerView(
            isEnabled: isEnabled,
            tabs: tabs,
            selectedTab: selectedTab
        )
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        view.update(
            isEnabled: isEnabled,
            tabs: tabs,
            selectedTab: selectedTab
        )
    }

    static func dismantleUIView(_ view: InstallerView, coordinator: ()) {
        view.uninstall()
    }

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        private var tabs: [NativeAppTab]
        private var selectedTab: NativeAppTab
        private let tabTap = UITapGestureRecognizer()
        private weak var installedWindow: UIWindow?
        private weak var installedTabBar: UITabBar?

        init(
            isEnabled: Bool,
            tabs: [NativeAppTab],
            selectedTab: NativeAppTab
        ) {
            self.tabs = tabs
            self.selectedTab = selectedTab
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            tabTap.addTarget(self, action: #selector(didTapTabBar(_:)))
            tabTap.cancelsTouchesInView = false
            tabTap.delegate = self
            tabTap.isEnabled = isEnabled
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                uninstall()
            } else {
                installIfNeeded()
            }
        }

        func update(
            isEnabled: Bool,
            tabs: [NativeAppTab],
            selectedTab: NativeAppTab
        ) {
            self.tabs = tabs
            self.selectedTab = selectedTab
            tabTap.isEnabled = isEnabled
            installIfNeeded()
            installTabTapIfNeeded()
        }

        func uninstall() {
            installedTabBar?.removeGestureRecognizer(tabTap)
            installedTabBar = nil
            installedWindow = nil
        }

        private func installIfNeeded() {
            guard let window, installedWindow !== window else { return }
            uninstall()
            installedWindow = window
            installTabTapIfNeeded()
        }

        private func installTabTapIfNeeded() {
            guard let tabBar = findTabBarController(from: installedWindow?.rootViewController)?.tabBar,
                  installedTabBar !== tabBar
            else { return }
            installedTabBar?.removeGestureRecognizer(tabTap)
            tabBar.addGestureRecognizer(tabTap)
            installedTabBar = tabBar
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func didTapTabBar(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let tabBar = installedTabBar,
                  let selectedIndex = tabs.firstIndex(of: selectedTab),
                  tappedTabIndex(at: recognizer.location(in: tabBar), in: tabBar) == selectedIndex,
                  let tabController = findTabBarController(from: installedWindow?.rootViewController),
                  let selectedController = tabController.selectedViewController,
                  let scrollView = primaryVerticalScrollView(in: selectedController.view)
            else { return }

            let topOffset = -scrollView.adjustedContentInset.top
            if scrollView.contentOffset.y > topOffset + 1 {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: topOffset),
                    animated: true
                )
            } else if let refreshControl = scrollView.refreshControl, !refreshControl.isRefreshing {
                refreshControl.beginRefreshing()
                refreshControl.sendActions(for: .valueChanged)
            }
        }

        private func tappedTabIndex(at location: CGPoint, in tabBar: UITabBar) -> Int? {
            let buttons = tabBarButtonViews(in: tabBar).sorted {
                $0.convert($0.bounds, to: tabBar).minX < $1.convert($1.bounds, to: tabBar).minX
            }
            if let index = buttons.firstIndex(where: {
                $0.convert($0.bounds, to: tabBar).contains(location)
            }) {
                return index
            }
            guard !tabs.isEmpty, tabBar.bounds.width > 0 else { return nil }
            return min(max(Int(location.x / (tabBar.bounds.width / CGFloat(tabs.count))), 0), tabs.count - 1)
        }

        private func tabBarButtonViews(in view: UIView) -> [UIView] {
            var result: [UIView] = []
            for subview in view.subviews {
                if String(describing: type(of: subview)).contains("UITabBarButton") {
                    result.append(subview)
                } else {
                    result.append(contentsOf: tabBarButtonViews(in: subview))
                }
            }
            return result
        }

        private func primaryVerticalScrollView(in view: UIView) -> UIScrollView? {
            var candidates: [UIScrollView] = []
            collectVerticalScrollViews(in: view, into: &candidates)
            return candidates.max {
                ($0.contentSize.height - $0.bounds.height) < ($1.contentSize.height - $1.bounds.height)
            }
        }

        private func collectVerticalScrollViews(in view: UIView, into result: inout [UIScrollView]) {
            guard !view.isHidden, view.alpha > 0.01, view.window != nil else { return }
            if let scrollView = view as? UIScrollView,
               scrollView.contentSize.height > scrollView.bounds.height || scrollView.refreshControl != nil {
                result.append(scrollView)
            }
            for subview in view.subviews {
                collectVerticalScrollViews(in: subview, into: &result)
            }
        }

        private func findTabBarController(from controller: UIViewController?) -> UITabBarController? {
            guard let controller else { return nil }
            if let tabController = controller as? UITabBarController { return tabController }
            if let presented = controller.presentedViewController,
               let result = findTabBarController(from: presented) {
                return result
            }
            for child in controller.children {
                if let result = findTabBarController(from: child) { return result }
            }
            return nil
        }
    }
}

private struct NativeQuestionRouteView: View {
    @StateObject private var store: QuestionStore
    let onNavigate: (QANavigationIntent) -> Void

    init(route: QuestionRouteDTO, repository: QuestionAnswerRepository, onNavigate: @escaping (QANavigationIntent) -> Void) {
        _store = StateObject(wrappedValue: QuestionStore(route: route, repository: repository))
        self.onNavigate = onNavigate
    }

    var body: some View { QuestionNativeView(store: store, onNavigate: onNavigate) }
}

private struct NativePersonRouteView: View {
    @StateObject private var model: PersonHostModel

    init(payload: PersonRoutePayload, accountStore: AccountJSONStore, onNavigate: @escaping (PersonNavigationIntent) -> Void) {
        _model = StateObject(wrappedValue: PersonHostModel(
            routeEntry: PersonRouteEntry(payload: payload),
            accountStore: accountStore,
            onNavigate: onNavigate
        ))
    }

    // Pushing a child route makes this view disappear temporarily. Do not dispose here: returning
    // must preserve the profile tab, paging state and scroll context.
    var body: some View { PersonHostView(model: model) }
}

@available(iOS 16.0, *)
private struct NativeCommentRouteView: View {
    @StateObject private var model: CommentHostModel

    init(route: CommentThreadRouteDTO, accountStore: AccountJSONStore, onPersonNavigate: @escaping (PersonNavigationIntent) -> Void) {
        _model = StateObject(wrappedValue: CommentHostModel(
            route: route,
            accountStore: accountStore,
            onPersonNavigate: onPersonNavigate
        ))
    }

    var body: some View { CommentHostView(model: model) }
}

private struct NativeSharePresentation: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct NativeShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct NativeSignedOutLibraryView: View {
    let title: String
    let openLogin: () -> Void
    var body: some View {
        NativeUnavailableState(
            title: title,
            message: "登录状态由本机 Keychain 安全保存",
            actionTitle: "登录知乎",
            action: openLogin
        )
        .navigationTitle("知乎++")
    }
}
