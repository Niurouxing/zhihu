import CoreSpotlight
import SwiftUI
import UIKit

enum NativeShellRoute: Hashable {
    case answer(AnswerRouteDTO)
    case question(QuestionRouteDTO)
    case person(PersonRoutePayload)
    case personConnections(PersonConnectionsRoute)
    case personWeb(PersonWebRoute)
    case pin(PinRouteDTO)
    case video(NativeVideoRouteDTO)
    case comments(CommentThreadRouteDTO)
    case search(SearchRouteDTO)
    case writeAnswer(WriteAnswerRouteDTO)
    case writePin
    case account
    case collections(userToken: String)
    case collectionContent(String)
    case special(String)
    case column(String)
    case history
    case notifications
    case notificationSettings
    case settings
    case systemAndUpdate

    var diagnosticRouteType: String {
        switch self {
        case .answer: return "answer"
        case .question: return "question"
        case .person: return "person"
        case .personConnections: return "person_connections"
        case .personWeb: return "person_web"
        case .pin: return "pin"
        case .video: return "video"
        case .comments: return "comments"
        case .search: return "search"
        case .writeAnswer: return "write_answer"
        case .writePin: return "write_pin"
        case .account: return "account"
        case .collections: return "collections"
        case .collectionContent: return "collection_content"
        case .special: return "special"
        case .column: return "column"
        case .history: return "history"
        case .notifications: return "notifications"
        case .notificationSettings: return "notification_settings"
        case .settings: return "settings"
        case .systemAndUpdate: return "system_and_update"
        }
    }

}

struct NativeNavigationEntry: Hashable, Identifiable {
    let id: UUID
    let route: NativeShellRoute
    let transition: NativeFeedTransitionContext?

    init(
        id: UUID = UUID(),
        route: NativeShellRoute,
        transition: NativeFeedTransitionContext? = nil
    ) {
        self.id = id
        self.route = route
        self.transition = transition
    }
}

private extension View {
    @ViewBuilder
    func nativeFeedNavigationDestinationTransition(
        sourceID: NativeFeedTransitionSourceID?,
        namespace: Namespace.ID
    ) -> some View {
        if let sourceID {
            navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }
}

struct NativeSearchFocusRequest: Equatable {
    let token: UInt
    let isActive: Bool

    static let inactive = Self(token: 0, isActive: false)
}

enum NativeSearchFocusRequestPolicy {
    static func nextToken(after current: UInt) -> UInt {
        let next = current &+ 1
        return next == 0 ? 1 : next
    }

    static func shouldConsume(
        _ request: NativeSearchFocusRequest,
        lastConsumedToken: UInt
    ) -> Bool {
        guard request.isActive, request.token != 0 else { return false }
        if lastConsumedToken == 0 { return true }
        let forwardDistance = request.token &- lastConsumedToken
        return forwardDistance > 0 && forwardDistance <= UInt.max / 2
    }

    static func pushedRouteRequest(_ route: SearchRouteDTO) -> NativeSearchFocusRequest {
        guard route.query.isEmpty else {
            return .inactive
        }
        return NativeSearchFocusRequest(token: 1, isActive: true)
    }

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
        case let .connections(route): return .personConnections(route)
        case let .search(route): return .search(route)
        case let .web(route): return .personWeb(route)
        }
    }
}

@MainActor
final class NativeNavigationState: ObservableObject {
    @Published private var path: [NativeNavigationEntry] = []
    private let diagnostics: PerformanceDiagnosticsClient

    init(diagnostics: PerformanceDiagnosticsClient = .disabled) {
        self.diagnostics = diagnostics
    }

    func binding() -> Binding<[NativeNavigationEntry]> {
        Binding(
            get: { self.path },
            set: { newPath in
                let oldPath = self.path
                if newPath.count < oldPath.count {
                    for entry in oldPath.dropFirst(newPath.count).reversed() {
                        self.record(entry.route, operation: "pop")
                    }
                }
                self.path = newPath
            }
        )
    }

    func navigate(
        to route: NativeShellRoute,
        transition: NativeFeedTransitionContext? = nil
    ) {
        if path.last?.route != route {
            path.append(NativeNavigationEntry(route: route, transition: transition))
            record(route, operation: "push")
        }
    }

    func replaceTop(with route: NativeShellRoute) {
        if !path.isEmpty { path.removeLast() }
        path.append(NativeNavigationEntry(route: route))
        record(route, operation: "replace")
    }

    var isAtRoot: Bool { path.isEmpty }

    func reset() { path.removeAll() }

    private func record(_ route: NativeShellRoute, operation: String) {
        diagnostics.record(.init(
            category: "navigation",
            operation: operation,
            result: .success,
            routeType: route.diagnosticRouteType
        ))
    }
}

private struct NativeMediaPresentation: Identifiable, Hashable {
    let id = UUID()
    let urls: [URL]
    let initialIndex: Int
}

@available(iOS 16.0, *)
struct NativeAppShell: View {
    let hostModel: HostModel
    let isAppUnlocked: Bool
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var preferences: NativeShellPreferences
    @ObservedObject private var account: NativeAccountStore
    @ObservedObject private var notifications: NativeNotificationStore
    @ObservedObject private var notificationPreferences: NativeNotificationPreferences

    @StateObject private var navigation: NativeNavigationState
    @StateObject private var recommendationStore: HomeFeedNativeStore
    @StateObject private var followingStore: FollowNativeStore
    @StateObject private var hotStore: HotFeedStore
    @StateObject private var dailyStore: DailyNativeStore
    @StateObject private var clipboardLinkMonitor = NativeClipboardZhihuLinkMonitor()
    @State private var selectedHomeChannelID: HomeChannel.ID
    @State private var mediaPresentation: NativeMediaPresentation?
    @State private var shareURL: URL?
    @State private var pendingShareChoiceURL: URL?
    @State private var showsCopiedLinkConfirmation = false
    @State private var clipboardInspectionArmed = false
    @State private var feedTransitionRegistry = NativeFeedTransitionRegistry()
    @Namespace private var feedNavigationNamespace

    init(hostModel: HostModel, isAppUnlocked: Bool) {
        self.hostModel = hostModel
        self.isAppUnlocked = isAppUnlocked
        _preferences = ObservedObject(wrappedValue: hostModel.preferences)
        _account = ObservedObject(wrappedValue: hostModel.account)
        _notifications = ObservedObject(wrappedValue: hostModel.notifications)
        _notificationPreferences = ObservedObject(wrappedValue: hostModel.notificationPreferences)
        _navigation = StateObject(wrappedValue: NativeNavigationState(
            diagnostics: hostModel.performanceDiagnostics.client
        ))
        _recommendationStore = StateObject(wrappedValue: HomeFeedNativeStore(
            repository: hostModel.homeRepository,
            configuration: {
                hostModel.preferences.homeRecommendationRefreshConfiguration
            },
            cachePersistence: hostModel.homeRecommendationCachePersistence,
            cacheAccountID: {
                hostModel.account.identity?.id
            },
            diagnostics: hostModel.performanceDiagnostics.client
        ))
        _followingStore = StateObject(wrappedValue: FollowNativeStore(repository: hostModel.followRepository))
        _hotStore = StateObject(wrappedValue: HotFeedStore(repository: hostModel.hotRepository))
        _dailyStore = StateObject(wrappedValue: DailyNativeStore(repository: hostModel.dailyRepository))
        _selectedHomeChannelID = State(initialValue: HomeChannel.recommendation.id)
    }

    var body: some View {
        rootNavigationStack
        .preferredColorScheme(preferences.themeMode.colorScheme)
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
        .alert(item: $clipboardLinkMonitor.candidate) { candidate in
            Alert(
                title: Text("发现知乎链接"),
                message: Text("是否在知乎++中打开？"),
                primaryButton: .default(Text("打开")) {
                    clipboardLinkMonitor.candidate = nil
                    openContent(candidate.destination)
                },
                secondaryButton: .cancel(Text("取消")) {
                    clipboardLinkMonitor.candidate = nil
                }
            )
        }
        .fullScreenCover(item: $mediaPresentation) { presentation in
            NativeMediaGallery(urls: presentation.urls, initialIndex: presentation.initialIndex)
        }
        .onChange(of: isAppUnlocked) { _, isUnlocked in
            if isUnlocked, scenePhase == .active {
                inspectClipboardAfterActivationIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                inspectClipboardAfterActivationIfNeeded()
            case .inactive, .background:
                clipboardInspectionArmed = true
                hostModel.feedAnswerPreloader.cancelSpeculativePreloads()
                hostModel.commentPreloader.cancelSpeculativePreloads()
                Task {
                    if selectedHomeChannelID == HomeChannel.recommendation.id {
                        await recommendationStore.recordLastViewed()
                    }
                    await recommendationStore.flushPendingCacheWrites()
                }
            @unknown default:
                clipboardInspectionArmed = true
                hostModel.feedAnswerPreloader.cancelSpeculativePreloads()
                hostModel.commentPreloader.cancelSpeculativePreloads()
                Task { await recommendationStore.flushPendingCacheWrites() }
            }
        }
        .onChange(of: account.identity.map { "\($0.id)|\($0.urlToken ?? "")" }) {
            navigation.reset()
            feedTransitionRegistry.reset()
            hostModel.feedAnswerPreloader.reset()
            hostModel.commentPreloader.reset()
            followingStore.accountDidChange()
            hotStore.accountDidChange()
            dailyStore.accountDidChange()
            notifications.accountDidChange()
            Task {
                await hostModel.apiClient.invalidateCredentialsCache()
                await recommendationStore.accountDidChange()
                switch HomeChannel(rawValue: selectedHomeChannelID) ?? .recommendation {
                case .recommendation:
                    await recommendationStore.loadInitialIfNeeded()
                case .following:
                    await followingStore.loadInitialIfNeeded()
                case .hot:
                    await hotStore.loadInitialIfNeeded()
                case .daily:
                    await dailyStore.loadInitialIfNeeded()
                }
                if account.isSignedIn {
                    await notifications.refresh()
                }
            }
        }
        .onChange(of: preferences.homeRecommendationSource) {
            Task { await recommendationStore.recommendationSourceDidChange() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )
        ) { _ in
            hostModel.feedAnswerPreloader.reset()
            hostModel.commentPreloader.reset()
        }
        .task {
            if case .loading = account.state { account.reloadFromKeychain() }
            if account.isSignedIn { await notifications.refreshUnreadCounts() }
            SystemNavigationRequestCenter.shared.installHandler(handleSystemNavigation)
            clipboardInspectionArmed = true
            inspectClipboardAfterActivationIfNeeded()
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
        .environment(\.nativeFeedNavigationNamespace, feedNavigationNamespace)
        .environment(\.nativeFeedTransitionRegistry, feedTransitionRegistry)
        .environment(\.nativeFeedAnswerPreloader, hostModel.feedAnswerPreloader)
        .environment(
            \.nativeHapticFeedback,
            .live(configuration: preferences.hapticFeedbackConfiguration)
        )
        .environmentObject(hostModel.questionAuthorBlocklist)
    }

    private var rootNavigationStack: some View {
        NavigationStack(path: navigation.binding()) {
            HomeChannelsNativeView(
                selectedChannelID: $selectedHomeChannelID,
                recommendationStore: recommendationStore,
                followingStore: followingStore,
                hotStore: hotStore,
                dailyStore: dailyStore,
                isOperationallyVisible: isAppUnlocked
                    && navigation.isAtRoot,
                notificationUnreadCount: notifications.unreadCount,
                accountAvatarURL: account.identity?.avatarURL,
                onOpenFeed: openFeed,
                onOpenPerson: { navigate(.person($0)) },
                onOpenDaily: handleDailyDestination,
                onOpenAccount: { navigate(.account) },
                onOpenSearch: openHomeSearch,
                onOpenCreation: { navigate(.writePin) },
                onOpenNotifications: { navigate(.notifications) }
            )
                .navigationDestination(for: NativeNavigationEntry.self) { entry in
                    destination(entry.route)
                        .nativeFeedNavigationDestinationTransition(
                            sourceID: entry.transition?.sourceID,
                            namespace: feedNavigationNamespace
                        )
                }
        }
    }

    @ViewBuilder
    private func destination(_ route: NativeShellRoute) -> some View {
        Group {
            switch route {
            case let .answer(route):
                ArticleHostView(
                    route: route,
                    repository: hostModel.questionAnswerRepository,
                    answerPreloader: hostModel.feedAnswerPreloader,
                    commentPreloader: hostModel.commentPreloader,
                    openedHistory: hostModel.answerOpenedHistory,
                    diagnostics: hostModel.performanceDiagnostics.client,
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
                diagnostics: hostModel.performanceDiagnostics.client,
                onNavigate: handlePersonIntent
            )
        case let .personConnections(route):
            NativePersonConnectionsRouteView(
                route: route,
                accountStore: hostModel.accountStore,
                diagnostics: hostModel.performanceDiagnostics.client,
                onNavigate: handlePersonIntent
            )
        case let .personWeb(route):
            PersonWebDestinationView(
                route: route,
                accountStore: hostModel.accountStore,
                openExternal: hostModel.openExternal
            )
        case let .pin(route):
            PinNativeView(
                route: route,
                repository: hostModel.pinRepository,
                onOpenPerson: { navigate(.person($0)) },
                onOpenLink: handlePinLink,
                onOpenComments: {
                    navigate(.comments(.init(subject: .pin($0))))
                }
            )
        case let .video(route):
            NativeVideoPlayerScreen(
                route: route,
                repository: hostModel.videoRepository,
                openExternal: hostModel.openExternal
            )
        case let .comments(route):
            NativeCommentNavigationRouteView(
                route: route,
                accountStore: hostModel.accountStore,
                repository: hostModel.commentRepository,
                preloader: hostModel.commentPreloader,
                onPersonNavigate: handlePersonIntent
            )
        case let .search(route):
            SearchNativeView(
                route: route,
                repository: hostModel.searchRepository,
                focusRequest: NativeSearchFocusRequestPolicy.pushedRouteRequest(route),
                onOpen: openFeed
            )
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
                ))) }
            )
        case .writePin:
            WritePinNativeView(
                repository: hostModel.creationRepository,
                onSystemIntent: handleCreationIntent,
                onPublished: { navigation.replaceTop(with: .pin(.init(pinID: $0))) }
            )
        case .account:
            NativeAccountView(store: account, actions: accountActions)
        case let .collections(token):
            NativeCollectionsView(userToken: token, repository: hostModel.libraryRepository, onOpenContent: openContent)
        case let .collectionContent(id):
            NativeCollectionContentView(collectionID: id, repository: hostModel.libraryRepository, onOpenContent: openContent)
        case let .special(id):
            NativeSpecialView(
                specialID: id,
                repository: hostModel.specialRepository,
                onOpenContent: openFeed
            )
        case let .column(id):
            NativeColumnView(
                columnID: id,
                repository: hostModel.columnRepository,
                onOpenContent: openContent
            )
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
                performanceDiagnostics: hostModel.performanceDiagnostics,
                setAppLock: hostModel.setAppLock
            )
            case .systemAndUpdate:
                SystemAndUpdateView(openExternalLink: hostModel.openSystemExternalLink)
            }
        }
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

    private func navigate(
        _ route: NativeShellRoute,
        transition: NativeFeedTransitionContext? = nil
    ) {
        navigation.navigate(
            to: route,
            transition: transition
        )
    }

    private func inspectClipboardAfterActivationIfNeeded() {
        guard clipboardInspectionArmed, isAppUnlocked else { return }
        clipboardInspectionArmed = false
        Task { await clipboardLinkMonitor.inspectIfNeeded() }
    }

    private func openFeed(_ route: FeedItemRoute) {
        let destination: NativeShellRoute
        switch route {
        case let .answer(id, questionID, title):
            destination = .answer(.init(
                contentID: id,
                kind: .answer,
                questionID: questionID,
                provisionalTitle: title
            ))
        case let .article(id, title):
            destination = .answer(.init(
                contentID: id,
                kind: .article,
                provisionalTitle: title
            ))
        case let .question(id, title):
            destination = .question(.init(questionID: id, provisionalTitle: title))
        case let .pin(id):
            destination = .pin(.init(pinID: id))
        case let .video(route):
            destination = .video(route)
        }
        navigate(
            destination,
            transition: feedTransitionRegistry.consume(
                contentID: route.navigationTransitionID
            )
        )
    }

    private func openHomeSearch() {
        navigate(.search(.init()))
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
        case let .special(id): navigate(.special(id))
        case let .column(id): navigate(.column(id))
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
            navigate(.comments(route))
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
        case let .video(route): navigate(.video(route))
        case let .share(url): handleShare(url)
        }
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
        clipboardLinkMonitor.recordAsHandled(url)
        showsCopiedLinkConfirmation = true
    }

    private func handleQALink(_ link: QALinkDestination) {
        switch link {
        case let .answer(id): navigate(.answer(.init(contentID: id, kind: .answer)))
        case let .article(id): navigate(.answer(.init(contentID: id, kind: .article)))
        case let .question(id): navigate(.question(.init(questionID: id)))
        case let .pin(id): navigate(.pin(.init(pinID: id)))
        case let .person(token):
            if let payload = PersonRoutePayload(memberID: nil, urlToken: token, displayName: "") {
                navigate(.person(payload))
            }
        case let .external(url): hostModel.openExternal(url)
        }
    }

    private func handlePersonIntent(_ intent: PersonNavigationIntent) {
        navigate(intent.nativeShellRoute)
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
            navigation.reset()
            selectedHomeChannelID = HomeChannel.hot.id
        case .collections:
            guard let token = account.identity?.collectionToken else {
                hostModel.openLogin()
                return
            }
            navigate(.collections(userToken: token))
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

    init(
        payload: PersonRoutePayload,
        accountStore: AccountJSONStore,
        diagnostics: PerformanceDiagnosticsClient = .disabled,
        onNavigate: @escaping (PersonNavigationIntent) -> Void
    ) {
        _model = StateObject(wrappedValue: PersonHostModel(
            routeEntry: PersonRouteEntry(payload: payload),
            accountStore: accountStore,
            diagnostics: diagnostics,
            onNavigate: onNavigate
        ))
    }

    // Pushing a child route makes this view disappear temporarily. Do not dispose here: returning
    // must preserve the profile tab, paging state and scroll context.
    var body: some View { PersonHostView(model: model) }
}

private struct NativePersonConnectionsRouteView: View {
    @StateObject private var model: PersonHostModel
    private let title: String

    init(
        route: PersonConnectionsRoute,
        accountStore: AccountJSONStore,
        diagnostics: PerformanceDiagnosticsClient = .disabled,
        onNavigate: @escaping (PersonNavigationIntent) -> Void
    ) {
        title = route.title
        _model = StateObject(wrappedValue: PersonHostModel(
            routeEntry: PersonRouteEntry(payload: route.person),
            accountStore: accountStore,
            diagnostics: diagnostics,
            onNavigate: onNavigate
        ))
    }

    var body: some View {
        PersonConnectionsView(model: model, title: title)
    }
}

@available(iOS 16.0, *)
private struct NativeCommentNavigationRouteView: View {
    @StateObject private var model: CommentHostModel

    init(
        route: CommentThreadRouteDTO,
        accountStore: AccountJSONStore,
        repository: CommentRepository,
        preloader: NativeCommentPreloader,
        onPersonNavigate: @escaping (PersonNavigationIntent) -> Void
    ) {
        _model = StateObject(wrappedValue: CommentHostModel(
            route: route,
            accountStore: accountStore,
            repository: repository,
            preloader: preloader,
            onPersonNavigate: onPersonNavigate
        ))
    }

    var body: some View { CommentNavigationPage(model: model) }
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
