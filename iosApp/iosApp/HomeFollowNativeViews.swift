import SwiftUI
import UIKit

struct NativeChannelTaskIdentity: Hashable {
    let isActive: Bool
    let value: String?
}

struct NativeFeedPaginationPrefetchTaskIdentity: Hashable {
    let isActive: Bool
    let nextPage: String?
    let isNearEnd: Bool
}

enum NativeFeedPaginationPrefetchPolicy {
    static let trailingItemCount = 5

    static func isNearEnd(
        itemIndex: Int,
        itemCount: Int,
        trailingItemCount: Int = NativeFeedPaginationPrefetchPolicy.trailingItemCount
    ) -> Bool {
        guard itemIndex >= 0,
              itemIndex < itemCount,
              itemCount > 0,
              trailingItemCount > 0
        else { return false }
        return itemIndex >= max(0, itemCount - trailingItemCount)
    }
}

struct NativeHomeFeedScrollView<Content: View>: View {
    private let minimumContentHeight: CGFloat
    private let content: Content

    init(
        minimumContentHeight: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.minimumContentHeight = minimumContentHeight
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                content
            }
            .frame(
                maxWidth: .infinity,
                minHeight: minimumContentHeight,
                alignment: .topLeading
            )
        }
    }
}

enum NativeHomeTopBarScrollIntent: Equatable {
    case show
    case hide
}

struct NativeHomeTopBarScrollIntentTracker {
    static let hideDistance: CGFloat = 18
    static let minimumOffsetToHide = NativeHomeTopChromeLayout.hiddenLeadingContentHeight
    static let showDistance: CGFloat = 4
    static let noiseTolerance: CGFloat = 0.5
    static let topTolerance: CGFloat = 1

    private var previousOffset: CGFloat?
    private var accumulatedDistance: CGFloat = 0
    private var direction: Direction?
    private var isInteracting = false

    mutating func updateInteraction(isInteracting: Bool, offset: CGFloat) {
        self.isInteracting = isInteracting
        previousOffset = offset.isFinite ? offset : nil
        accumulatedDistance = 0
        direction = nil
    }

    mutating func updateOffset(
        _ offset: CGFloat,
        isActive: Bool
    ) -> NativeHomeTopBarScrollIntent? {
        guard offset.isFinite else {
            reset()
            return nil
        }

        guard isActive else {
            reset(offset: offset)
            return nil
        }

        if offset <= Self.topTolerance {
            previousOffset = offset
            accumulatedDistance = 0
            direction = nil
            return .show
        }

        guard isInteracting, let previousOffset else {
            self.previousOffset = offset
            return nil
        }

        let delta = offset - previousOffset
        guard abs(delta) >= Self.noiseTolerance else { return nil }
        self.previousOffset = offset

        let newDirection: Direction = delta > 0 ? .towardLaterContent : .towardEarlierContent
        if direction == newDirection {
            accumulatedDistance += abs(delta)
        } else {
            direction = newDirection
            accumulatedDistance = abs(delta)
        }

        switch newDirection {
        case .towardLaterContent
            where accumulatedDistance >= Self.hideDistance
                && offset >= Self.minimumOffsetToHide:
            accumulatedDistance = 0
            return .hide
        case .towardEarlierContent where accumulatedDistance >= Self.showDistance:
            accumulatedDistance = 0
            return .show
        default:
            return nil
        }
    }

    mutating func reset(offset: CGFloat? = nil) {
        previousOffset = offset?.isFinite == true ? offset : nil
        accumulatedDistance = 0
        direction = nil
        isInteracting = false
    }

    private enum Direction {
        case towardLaterContent
        case towardEarlierContent
    }
}

private struct NativeHomeTopBarScrollIntentActionKey: EnvironmentKey {
    static let defaultValue: (NativeHomeTopBarScrollIntent) -> Void = { _ in }
}

extension EnvironmentValues {
    var nativeHomeTopBarScrollIntentAction: (NativeHomeTopBarScrollIntent) -> Void {
        get { self[NativeHomeTopBarScrollIntentActionKey.self] }
        set { self[NativeHomeTopBarScrollIntentActionKey.self] = newValue }
    }
}

@MainActor
final class NativeHomeScrollPositionRegistry {
    private var offsets: [HomeChannel: CGFloat] = [:]

    func offset(for channel: HomeChannel) -> CGFloat? {
        offsets[channel]
    }

    func save(_ offset: CGFloat, for channel: HomeChannel) {
        guard offset.isFinite else { return }
        offsets[channel] = max(offset, NativeHomeTopChromeLayout.revealedOffset)
    }

    func reset() {
        offsets.removeAll()
    }
}

private struct NativeHomeScrollPositionRegistryKey: EnvironmentKey {
    static let defaultValue: NativeHomeScrollPositionRegistry? = nil
}

extension EnvironmentValues {
    var nativeHomeScrollPositionRegistry: NativeHomeScrollPositionRegistry? {
        get { self[NativeHomeScrollPositionRegistryKey.self] }
        set { self[NativeHomeScrollPositionRegistryKey.self] = newValue }
    }
}

enum NativeHomeTopChromeLayout {
    static let height: CGFloat = 56
    static let refreshRevealHeight = height
    static let searchDrawerHeight = height
    static let revealedOffset: CGFloat = 0
    static let collapsedOffset = refreshRevealHeight
    static let hiddenLeadingContentHeight = refreshRevealHeight + searchDrawerHeight
    static let searchFieldHeight: CGFloat = 36
    static let searchBottomInset: CGFloat = 6

    static func refreshPullDistance(normalizedOffset: CGFloat) -> CGFloat {
        max(-normalizedOffset, 0)
    }
}

struct NativeHomeRefreshRevealSpacer: View {
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                Text("正在刷新")
            } else {
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.semibold))
                Text("继续下拉刷新")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(height: NativeHomeTopChromeLayout.refreshRevealHeight)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

struct NativeHomePullSearchDrawer: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Button(action: action) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.medium))
                    Text("搜索知乎")
                        .font(.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(
                    maxWidth: .infinity,
                    minHeight: NativeHomeTopChromeLayout.searchFieldHeight,
                    alignment: .leading
                )
                .background(
                    Color(uiColor: .tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.bottom, NativeHomeTopChromeLayout.searchBottomInset)
        }
        .frame(height: NativeHomeTopChromeLayout.searchDrawerHeight)
        // The persistent channel control exposes the same search action to VoiceOver.
        .accessibilityHidden(true)
    }
}

enum NativeHomeSearchDrawerSnapTarget: Equatable {
    case revealed
    case collapsed
}

struct NativeHomeSearchDrawerSnapPolicy {
    static let revealThreshold: CGFloat = 18
    static let settledTolerance: CGFloat = 0.75

    static func target(
        normalizedOffset: CGFloat,
        drawerHeight: CGFloat = NativeHomeTopChromeLayout.searchDrawerHeight,
        isRefreshing: Bool
    ) -> NativeHomeSearchDrawerSnapTarget? {
        guard normalizedOffset.isFinite, !isRefreshing else { return nil }
        guard normalizedOffset >= -settledTolerance,
              normalizedOffset <= drawerHeight + settledTolerance
        else { return nil }
        if normalizedOffset <= settledTolerance { return .revealed }
        if normalizedOffset >= drawerHeight - settledTolerance { return .collapsed }
        let visibleHeight = drawerHeight - normalizedOffset
        return visibleHeight >= revealThreshold ? .revealed : .collapsed
    }
}

private struct NativeHomeScrollRuntimeConfiguration: Equatable {
    let isActive: Bool
    let scrollToTopRequest: UInt
    let hasSearchDrawer: Bool
    let isRefreshing: Bool
    let restoredNormalizedOffset: CGFloat?
}

/// Owns the native scroll interaction without publishing per-pixel offsets into SwiftUI.
/// Search reveal is represented by the scroll view's natural 0...drawerHeight range;
/// refresh begins only after that range has been fully traversed.
private struct NativeHomeScrollRuntimeBridge: UIViewRepresentable {
    let configuration: NativeHomeScrollRuntimeConfiguration
    let onIntent: (NativeHomeTopBarScrollIntent) -> Void
    let onPrepared: () -> Void
    let onOffsetSaved: (CGFloat) -> Void

    func makeUIView(context: Context) -> NativeHomeScrollRuntimeView {
        let view = NativeHomeScrollRuntimeView()
        view.configure(
            configuration: configuration,
            onIntent: onIntent,
            onPrepared: onPrepared,
            onOffsetSaved: onOffsetSaved
        )
        return view
    }

    func updateUIView(_ uiView: NativeHomeScrollRuntimeView, context: Context) {
        uiView.configure(
            configuration: configuration,
            onIntent: onIntent,
            onPrepared: onPrepared,
            onOffsetSaved: onOffsetSaved
        )
    }

    static func dismantleUIView(
        _ uiView: NativeHomeScrollRuntimeView,
        coordinator: ()
    ) {
        uiView.uninstall()
    }
}

private final class NativeHomeScrollRuntimeView: UIView {
    private weak var scrollView: UIScrollView?
    private var configuration = NativeHomeScrollRuntimeConfiguration(
        isActive: false,
        scrollToTopRequest: 0,
        hasSearchDrawer: false,
        isRefreshing: false,
        restoredNormalizedOffset: nil
    )
    private var onIntent: (NativeHomeTopBarScrollIntent) -> Void = { _ in }
    private var onPrepared: () -> Void = {}
    private var onOffsetSaved: (CGFloat) -> Void = { _ in }
    private var tracker = NativeHomeTopBarScrollIntentTracker()
    private var lastHandledScrollRequest: UInt?
    private var didPrepareInitialPosition = false
    private var isInstallationScheduled = false
    private var isProgrammaticScrollScheduled = false

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        scheduleInstallation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleInstallation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView == nil {
            scheduleInstallation()
        } else {
            prepareInitialPositionIfPossible()
        }
    }

    func configure(
        configuration: NativeHomeScrollRuntimeConfiguration,
        onIntent: @escaping (NativeHomeTopBarScrollIntent) -> Void,
        onPrepared: @escaping () -> Void,
        onOffsetSaved: @escaping (CGFloat) -> Void
    ) {
        let wasActive = self.configuration.isActive
        self.configuration = configuration
        self.onIntent = onIntent
        self.onPrepared = onPrepared
        self.onOffsetSaved = onOffsetSaved

        if lastHandledScrollRequest == nil {
            lastHandledScrollRequest = configuration.scrollToTopRequest
        } else if configuration.isActive,
                  didPrepareInitialPosition,
                  configuration.scrollToTopRequest != lastHandledScrollRequest {
            lastHandledScrollRequest = configuration.scrollToTopRequest
            scheduleScrollToCollapsedPosition(animated: true)
        }

        if wasActive, !configuration.isActive {
            saveCurrentOffset()
            tracker.reset()
        }
        scheduleInstallation()
    }

    func uninstall() {
        saveCurrentOffset()
        scrollView?.panGestureRecognizer.removeTarget(
            self,
            action: #selector(handlePan(_:))
        )
        scrollView = nil
        isInstallationScheduled = false
        isProgrammaticScrollScheduled = false
        tracker.reset()
    }

    private func scheduleInstallation() {
        guard !isInstallationScheduled else { return }
        isInstallationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isInstallationScheduled = false
            self.installIfNeeded()
        }
    }

    private func installIfNeeded() {
        guard window != nil, let candidate = enclosingScrollView() else { return }
        if scrollView !== candidate {
            scrollView?.panGestureRecognizer.removeTarget(
                self,
                action: #selector(handlePan(_:))
            )
            candidate.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
            scrollView = candidate
        }
        candidate.layoutIfNeeded()
        prepareInitialPositionIfPossible()
    }

    private func enclosingScrollView() -> UIScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView { return scrollView }
            candidate = view.superview
        }
        return nil
    }

    private func prepareInitialPositionIfPossible() {
        guard !didPrepareInitialPosition, let scrollView else { return }
        guard scrollView.bounds.height > 0 else { return }

        if configuration.hasSearchDrawer {
            let minimumOffset = NativeHomeTopChromeLayout.collapsedOffset
            let maximumOffset = maximumNormalizedOffset(in: scrollView)
            guard maximumOffset
                    >= minimumOffset - NativeHomeSearchDrawerSnapPolicy.settledTolerance
            else { return }
            let restoredOffset = configuration.restoredNormalizedOffset
                .flatMap { $0.isFinite ? $0 : nil }
            let targetOffset = min(
                max(restoredOffset ?? minimumOffset, NativeHomeTopChromeLayout.revealedOffset),
                maximumOffset
            )
            setNormalizedOffset(targetOffset, in: scrollView, animated: false)
        }

        didPrepareInitialPosition = true
        DispatchQueue.main.async { [weak self] in
            self?.onPrepared()
        }
    }

    private func scheduleScrollToCollapsedPosition(animated: Bool) {
        guard !isProgrammaticScrollScheduled else { return }
        isProgrammaticScrollScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isProgrammaticScrollScheduled = false
            guard self.configuration.isActive,
                  let scrollView = self.scrollView
            else { return }
            self.setNormalizedOffset(
                self.configuration.hasSearchDrawer
                    ? NativeHomeTopChromeLayout.collapsedOffset
                    : 0,
                in: scrollView,
                animated: animated
            )
            self.onOffsetSaved(
                self.configuration.hasSearchDrawer
                    ? NativeHomeTopChromeLayout.collapsedOffset
                    : 0
            )
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let scrollView, configuration.isActive else { return }
        let offset = normalizedOffset(in: scrollView)
        switch recognizer.state {
        case .began:
            tracker.updateInteraction(isInteracting: true, offset: offset)
        case .changed:
            if let intent = tracker.updateOffset(offset, isActive: true) {
                onIntent(intent)
            }
        case .ended:
            _ = tracker.updateOffset(offset, isActive: true)
            tracker.updateInteraction(isInteracting: false, offset: offset)
            settleSearchDrawer(in: scrollView, normalizedOffset: offset)
            saveCurrentOffset()
        case .cancelled, .failed:
            tracker.updateInteraction(isInteracting: false, offset: offset)
            saveCurrentOffset()
        default:
            break
        }
    }

    private func settleSearchDrawer(
        in scrollView: UIScrollView,
        normalizedOffset: CGFloat
    ) {
        guard configuration.hasSearchDrawer,
              let target = NativeHomeSearchDrawerSnapPolicy.target(
                normalizedOffset: normalizedOffset,
                isRefreshing: configuration.isRefreshing
              )
        else { return }
        let targetOffset = target == .revealed
            ? NativeHomeTopChromeLayout.revealedOffset
            : NativeHomeTopChromeLayout.collapsedOffset
        guard abs(normalizedOffset - targetOffset)
                > NativeHomeSearchDrawerSnapPolicy.settledTolerance
        else { return }
        setNormalizedOffset(targetOffset, in: scrollView, animated: true)
        onOffsetSaved(targetOffset)
    }

    private func normalizedOffset(in scrollView: UIScrollView) -> CGFloat {
        scrollView.contentOffset.y + scrollView.adjustedContentInset.top
    }

    private func saveCurrentOffset() {
        guard didPrepareInitialPosition, let scrollView else { return }
        onOffsetSaved(normalizedOffset(in: scrollView))
    }

    private func maximumNormalizedOffset(in scrollView: UIScrollView) -> CGFloat {
        max(
            0,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.top
                + scrollView.adjustedContentInset.bottom
        )
    }

    private func setNormalizedOffset(
        _ normalizedOffset: CGFloat,
        in scrollView: UIScrollView,
        animated: Bool
    ) {
        let contentOffsetY = normalizedOffset - scrollView.adjustedContentInset.top
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: contentOffsetY),
            animated: animated
        )
    }
}

/// Shared channel surface. It keeps only semantic refresh/readiness state in SwiftUI;
/// all continuous gesture state remains inside the native scroll view.
struct NativeHomeChannelScrollView<Content: View>: View {
    @Environment(\.nativeHomeTopBarScrollIntentAction) private var onTopBarIntent
    @Environment(\.nativeHomeScrollPositionRegistry) private var positionRegistry
    @State private var isPrepared: Bool
    @State private var isPullRefreshInFlight = false

    let channel: HomeChannel
    let isActive: Bool
    let scrollToTopRequest: UInt
    let isRefreshing: Bool
    let onOpenSearch: (() -> Void)?
    let onRefresh: () async -> Void
    private let content: Content

    init(
        channel: HomeChannel,
        isActive: Bool,
        scrollToTopRequest: UInt,
        isRefreshing: Bool,
        onOpenSearch: (() -> Void)?,
        onRefresh: @escaping () async -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.channel = channel
        self.isActive = isActive
        self.scrollToTopRequest = scrollToTopRequest
        self.isRefreshing = isRefreshing
        self.onOpenSearch = onOpenSearch
        self.onRefresh = onRefresh
        self.content = content()
        _isPrepared = State(initialValue: onOpenSearch == nil)
    }

    var body: some View {
        GeometryReader { viewport in
            NativeHomeFeedScrollView(
                minimumContentHeight: viewport.size.height
                    + (onOpenSearch == nil ? 0 : NativeHomeTopChromeLayout.searchDrawerHeight)
            ) {
                NativeHomeScrollRuntimeBridge(
                    configuration: NativeHomeScrollRuntimeConfiguration(
                        isActive: isActive,
                        scrollToTopRequest: scrollToTopRequest,
                        hasSearchDrawer: onOpenSearch != nil,
                        isRefreshing: effectiveIsRefreshing,
                        restoredNormalizedOffset: positionRegistry?.offset(for: channel)
                    ),
                    onIntent: onTopBarIntent,
                    onPrepared: markPrepared,
                    onOffsetSaved: saveOffset
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

                if let onOpenSearch {
                    NativeHomeRefreshRevealSpacer(
                        isRefreshing: effectiveIsRefreshing
                    )
                    NativeHomePullSearchDrawer(
                        action: onOpenSearch
                    )
                }

                content
            }
            .refreshable {
                guard isActive, !isPullRefreshInFlight else { return }
                isPullRefreshInFlight = true
                defer { isPullRefreshInFlight = false }
                await onRefresh()
            }
            .opacity(isPrepared ? 1 : 0)
            .allowsHitTesting(isPrepared)
        }
    }

    private var effectiveIsRefreshing: Bool {
        isPullRefreshInFlight || isRefreshing
    }

    private func markPrepared() {
        guard !isPrepared else { return }
        isPrepared = true
    }

    private func saveOffset(_ offset: CGFloat) {
        positionRegistry?.save(offset, for: channel)
    }
}

@available(iOS 16.0, *)
struct HomeNativeView: View {
    @ObservedObject private var store: HomeFeedNativeStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeChannelIsActive) private var isActiveChannel
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    let scrollToTopRequest: UInt
    private let onOpenSearch: (() -> Void)?
    let onOpen: (FeedItemRoute) -> Void

    init(
        store: HomeFeedNativeStore,
        scrollToTopRequest: UInt,
        onOpenSearch: (() -> Void)? = nil,
        onOpen: @escaping (FeedItemRoute) -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.scrollToTopRequest = scrollToTopRequest
        self.onOpenSearch = onOpenSearch
        self.onOpen = onOpen
    }

    var body: some View {
        let items = visibleItems
        NativeHomeChannelScrollView(
            channel: .recommendation,
            isActive: isActiveChannel,
            scrollToTopRequest: scrollToTopRequest,
            isRefreshing: store.isRefreshing,
            onOpenSearch: onOpenSearch,
            onRefresh: refresh
        ) {
            if items.isEmpty {
                recommendationEmptyState
            }

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let prefetchTaskID = NativeFeedPaginationPrefetchTaskIdentity(
                    isActive: isActiveChannel,
                    nextPage: store.nextPageLoadID,
                    isNearEnd: NativeFeedPaginationPrefetchPolicy.isNearEnd(
                        itemIndex: index,
                        itemCount: items.count
                    )
                )
                FeedItemRow(item: item, showsThumbnail: true) { route in
                    store.opened(item)
                    onOpen(route)
                }
                .nativeFeedCardItemLayout()
                .task(id: prefetchTaskID) {
                    guard prefetchTaskID.isActive,
                          prefetchTaskID.isNearEnd,
                          prefetchTaskID.nextPage != nil,
                          prefetchTaskID.nextPage == store.nextPageLoadID
                    else { return }
                    await store.loadMore()
                }
            }

            if !items.isEmpty, let message = store.errorMessage {
                FeedRetryRow(message: message) { Task { await store.retry() } }
                    .nativeFeedCardItemLayout()
            } else if !items.isEmpty, store.isLoading {
                NativeFeedPaginationLoadingRow(title: "正在加载更多推荐")
            }

            // Pagination is driven by the trailing visible cards above. A footer
            // task can remain mounted after it moves off-screen and recursively
            // consume every continuation while the user is idle.
        }
        .onChange(of: store.refreshFeedbackSequence) { _, _ in
            guard isActiveChannel else { return }
            hapticFeedback(.refreshSucceeded)
        }
        .task(id: isActiveChannel) {
            guard isActiveChannel else { return }
            await store.loadInitialIfNeeded()
        }
        .accessibilityIdentifier("home_native")
    }

    private var visibleItems: [FeedItemDTO] {
        FeedQuestionAuthorVisibilityPolicy.visibleItems(
            from: store.items,
            blockedMemberIDs: questionAuthorBlocklist.blockedMemberIDs
        )
    }

    @ViewBuilder
    private var recommendationEmptyState: some View {
        if store.isLoading {
            HStack { Spacer(); ProgressView("正在加载推荐"); Spacer() }
        } else if let message = store.errorMessage {
            FeedRetryRow(message: message) { Task { await store.retry() } }
                .nativeFeedCardItemLayout()
        } else if !store.hasNextPage {
            Label("暂无推荐", systemImage: "sparkles")
                .foregroundStyle(.secondary)
        }
    }

    private func refresh() async {
        guard isActiveChannel else { return }
        let outcome = await store.refresh(intent: .pull)
        if outcome == .ignored {
            hapticFeedback(.refreshIgnored)
        }
    }
}

struct FollowNativeView: View {
    @ObservedObject private var store: FollowNativeStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeChannelIsActive) private var isActiveChannel
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    let scrollToTopRequest: UInt
    private let onOpenSearch: (() -> Void)?
    let onOpen: (FeedItemRoute) -> Void
    let onOpenPerson: (PersonRoutePayload) -> Void

    init(
        store: FollowNativeStore,
        scrollToTopRequest: UInt,
        onOpenSearch: (() -> Void)? = nil,
        onOpen: @escaping (FeedItemRoute) -> Void,
        onOpenPerson: @escaping (PersonRoutePayload) -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.scrollToTopRequest = scrollToTopRequest
        self.onOpenSearch = onOpenSearch
        self.onOpen = onOpen
        self.onOpenPerson = onOpenPerson
    }

    var body: some View {
        let items = visibleItems
        NativeHomeChannelScrollView(
            channel: .following,
            isActive: isActiveChannel,
            scrollToTopRequest: scrollToTopRequest,
            isRefreshing: store.isMomentsRefreshing,
            onOpenSearch: onOpenSearch,
            onRefresh: refresh
        ) {
            recentUsers

            if store.moments.items.isEmpty, store.moments.isLoading {
                HStack { Spacer(); ProgressView("正在加载关注内容"); Spacer() }
            }

            ForEach(items) { item in
                FeedItemRow(item: item, showsThumbnail: true, onOpen: onOpen)
                    .nativeFeedCardItemLayout()
            }

            if let message = store.moments.errorMessage {
                FeedRetryRow(message: message) {
                    Task { await store.retry(section: .moments) }
                }
                .nativeFeedCardItemLayout()
            } else if store.moments.hasNextPage {
                let taskID = NativeChannelTaskIdentity(
                    isActive: isActiveChannel,
                    value: store.moments.nextPageLoadID
                )
                NativeFeedPaginationLoadingRow(title: "正在加载更多关注内容")
                    .task(id: taskID) {
                        guard taskID.isActive,
                              taskID.value == store.moments.nextPageLoadID
                        else { return }
                        await store.loadMore(section: .moments)
                    }
            } else if items.isEmpty, !store.moments.isLoading {
                Label("暂无关注内容", systemImage: "person.2")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: NativeChannelTaskIdentity(
            isActive: isActiveChannel,
            value: FollowSection.moments.rawValue
        )) {
            guard isActiveChannel else { return }
            await store.loadMomentsIfNeeded()
        }
        .accessibilityIdentifier("follow_native")
    }

    private var visibleItems: [FeedItemDTO] {
        FeedQuestionAuthorVisibilityPolicy.visibleItems(
            from: store.moments.items,
            blockedMemberIDs: questionAuthorBlocklist.blockedMemberIDs
        )
    }

    @ViewBuilder
    private var recentUsers: some View {
        if !store.recentUsers.isEmpty {
            Section("最近动态") {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(store.recentUsers) { user in
                            Button {
                                if let route = user.personRoute { onOpenPerson(route) }
                            } label: {
                                VStack(spacing: 6) {
                                    AsyncImage(url: user.avatarURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Color.secondary.opacity(0.15)
                                    }
                                    .frame(width: 52, height: 52)
                                    .clipShape(Circle())
                                    .overlay(alignment: .topTrailing) {
                                        if user.unreadCount > 0 {
                                            Circle().fill(.red).frame(width: 10, height: 10)
                                                .overlay(Circle().stroke(.background, lineWidth: 2))
                                        }
                                    }
                                    Text(user.displayName)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(width: 64)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(user.unreadCount > 0
                                ? "\(user.displayName)，有新动态"
                                : user.displayName)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } else if let error = store.recentUsersErrorMessage {
            Section("最近动态") {
                FeedRetryRow(message: error) { Task { await store.reloadRecentUsers() } }
                    .nativeFeedCardItemLayout()
            }
        }
    }

    private func refresh() async {
        guard isActiveChannel else { return }
        let previousSuccessfulRefresh = store.refreshMetadata.lastSuccessfulRefreshAt
        await store.refresh(section: .moments)
        if !Task.isCancelled,
           NativeRefreshHapticPolicy.shouldEmit(
            previousSuccessfulRefreshAt: previousSuccessfulRefresh,
            currentSuccessfulRefreshAt: store.refreshMetadata.lastSuccessfulRefreshAt
           ) {
            hapticFeedback(.refreshSucceeded)
        }
    }
}

private struct NativeFeedPaginationLoadingRow: View {
    let title: String

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            ProgressView(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feed_pagination_loading")
    }
}
