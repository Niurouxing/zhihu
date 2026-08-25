import SwiftUI

struct NativeChannelTaskIdentity: Hashable {
    let isActive: Bool
    let value: String?
}

private struct NativeHomeFeedListLayout: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content.environment(\.defaultMinListRowHeight, 1)
    }
}

private struct NativeHomeFeedScrollTracking: ViewModifier {
    @Binding var collapseProgress: CGFloat
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                NativeHomeFeedScrollMetrics.collapseProgress(
                    contentOffsetY: geometry.contentOffset.y,
                    contentInsetTop: geometry.contentInsets.top
                )
            } action: { _, newProgress in
                guard isActive else { return }
                collapseProgress = newProgress
            }
        } else {
            content
        }
    }
}

enum NativeHomeFeedScrollMetrics {
    static let collapseDistance = NativeHomeHeaderLayoutPolicy.expandedHeaderHeight
    static let fallbackCollapseDistance: CGFloat = collapseDistance

    static func collapseProgress(
        contentOffsetY: CGFloat,
        contentInsetTop: CGFloat
    ) -> CGFloat {
        let effectiveOffset = contentOffsetY + contentInsetTop
        return min(max(effectiveOffset / collapseDistance, 0), 1)
    }
}

struct NativeScrollToTopRequestPolicy {
    static func shouldHandleChange(
        previousRequest: UInt,
        newRequest: UInt
    ) -> Bool {
        newRequest > 0 && newRequest != previousRequest
    }
}

struct NativeHomeHeaderLayoutPolicy {
    static let horizontalContentInset: CGFloat = 20
    static let expandedTitleHeight: CGFloat = 76
    static let channelSelectorHeight: CGFloat = 60
    static let expandedHeaderHeight = expandedTitleHeight + channelSelectorHeight

    static func normalized(_ collapseProgress: CGFloat) -> CGFloat {
        min(max(collapseProgress, 0), 1)
    }

    static func visibleHeaderHeight(collapseProgress: CGFloat) -> CGFloat {
        expandedHeaderHeight * (1 - normalized(collapseProgress))
    }

    static func listViewportOrigin(collapseProgress _: CGFloat) -> CGFloat {
        0
    }

    static func scrollAnchor(for channel: HomeChannel) -> HomeChannel {
        channel
    }
}

enum NativeHomeContentScrollTarget: Hashable {
    case recommendation(FeedItemID)
    case recommendationStatus
    case followingRecentUsers
    case following(FeedItemID)
    case followingStatus
    case hot(FeedItemID)
    case hotStatus
    case daily(Int64)
    case dailyStatus

    var representsLoadedContent: Bool {
        switch self {
        case .recommendationStatus, .followingStatus, .hotStatus, .dailyStatus:
            false
        default:
            true
        }
    }
}

@MainActor
enum NativeHomeSearchEntryScrollController {
    static func hideIfNeeded(
        in proxy: ScrollViewProxy,
        target: NativeHomeContentScrollTarget?,
        isActive: Bool,
        lastHiddenTarget: Binding<NativeHomeContentScrollTarget?>
    ) {
        guard isActive,
              let target
        else { return }

        if let previousTarget = lastHiddenTarget.wrappedValue {
            guard previousTarget != target,
                  !previousTarget.representsLoadedContent
            else { return }
        }

        lastHiddenTarget.wrappedValue = target
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .top)
            // A List can publish the target one layout pass before its final row geometry.
            // Repeating on the next pass keeps the search entry reliably above the viewport.
            DispatchQueue.main.async {
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }
}

struct NativeHomeGlobalSearchEntry: View {
    let action: () -> Void

    var body: some View {
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
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                Color(uiColor: .tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel("搜索知乎")
        .accessibilityHint("打开全站搜索")
        .accessibilityIdentifier("home_global_search_entry")
    }
}

struct NativeRootHeaderVisibility {
    static let compactThreshold: CGFloat = 0.5
    static let crossfadeLowerBound: CGFloat = 0.35
    static let crossfadeUpperBound: CGFloat = 0.65

    static func expandedOpacity(collapseProgress: CGFloat) -> Double {
        1 - compactOpacity(collapseProgress: collapseProgress)
    }

    static func compactOpacity(collapseProgress: CGFloat) -> Double {
        let progress = normalized(collapseProgress)
        guard progress > crossfadeLowerBound else { return 0 }
        guard progress < crossfadeUpperBound else { return 1 }

        let range = crossfadeUpperBound - crossfadeLowerBound
        let fraction = (progress - crossfadeLowerBound) / range
        return Double(fraction * fraction * (3 - 2 * fraction))
    }

    static func usesCompactSemantics(collapseProgress: CGFloat) -> Bool {
        normalized(collapseProgress) >= compactThreshold
    }

    private static func normalized(_ collapseProgress: CGFloat) -> CGFloat {
        min(max(collapseProgress, 0), 1)
    }
}

struct NativeHomeRefreshIndicatorPresentation {
    static let minimumPullDistance: CGFloat = 8

    static func isVisible(
        pullDistance: CGFloat,
        isRefreshing: Bool
    ) -> Bool {
        isRefreshing || pullDistance >= minimumPullDistance
    }
}

extension View {
    func nativeHomeFeedListLayout() -> some View {
        modifier(NativeHomeFeedListLayout())
    }

    func nativeHomeFeedScrollTracking(
        collapseProgress: Binding<CGFloat>,
        isActive: Bool
    ) -> some View {
        modifier(NativeHomeFeedScrollTracking(
            collapseProgress: collapseProgress,
            isActive: isActive
        ))
    }

}

private struct NativeRootTitleOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .nan
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct NativeRootLargeTitle: View {
    let title: String
    let coordinateSpaceName: String
    let displaysTitle: Bool
    let isActive: Bool
    let isRefreshing: Bool
    @Binding var collapseProgress: CGFloat
    @State private var latestMinY: CGFloat = .nan
    @State private var fallbackIsCollapsed = false

    init(
        _ title: String,
        coordinateSpaceName: String = "home-root-scroll",
        displaysTitle: Bool = true,
        isActive: Bool = true,
        isRefreshing: Bool = false,
        collapseProgress: Binding<CGFloat>
    ) {
        self.title = title
        self.coordinateSpaceName = coordinateSpaceName
        self.displaysTitle = displaysTitle
        self.isActive = isActive
        self.isRefreshing = isRefreshing
        _collapseProgress = collapseProgress
    }

    var body: some View {
        Group {
            if displaysTitle {
                Text(title)
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(1 - collapseProgress)
                    .offset(y: -6 * collapseProgress)
            } else {
                Color.clear
                    .frame(height: NativeHomeHeaderLayoutPolicy.expandedHeaderHeight)
                    .overlay(alignment: .top) {
                        if NativeHomeRefreshIndicatorPresentation.isVisible(
                            pullDistance: pullDistance,
                            isRefreshing: isRefreshing
                        ) {
                            // The native refresh control lives above this transparent spacer
                            // and is covered by the fixed opaque header. Keeping one indicator
                            // inside the spacer makes it enter the revealed overscroll region.
                            ProgressView()
                                .controlSize(.regular)
                                .padding(.top, 14)
                                .accessibilityLabel("正在更新")
                                .accessibilityIdentifier("home_refresh_indicator")
                        }
                    }
            }
        }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: NativeRootTitleOffsetKey.self,
                        value: geometry.frame(in: .named(coordinateSpaceName)).minY
                    )
                }
            }
            .onPreferenceChange(NativeRootTitleOffsetKey.self) { minY in
                guard minY.isFinite else { return }
                latestMinY = minY
                reportCollapseProgress(minY: minY)
            }
            .onChange(of: isActive) { active in
                guard active, latestMinY.isFinite else { return }
                reportCollapseProgress(minY: latestMinY)
            }
            .listRowInsets(displaysTitle
                ? EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
                : EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityHidden(!displaysTitle)
            .accessibilityAddTraits(.isHeader)
    }

    private func reportCollapseProgress(minY: CGFloat) {
        guard isActive else { return }
        if #available(iOS 18.0, *) { return }
        let progress = min(
            max(-minY / NativeHomeFeedScrollMetrics.fallbackCollapseDistance, 0),
            1
        )
        if progress >= 1 {
            fallbackIsCollapsed = true
            collapseProgress = 1
            return
        }
        if fallbackIsCollapsed {
            // A virtualized probe can emit its default value after leaving the List.
            // Keep the collapsed state until the real probe re-enters from above.
            if minY > 0 {
                fallbackIsCollapsed = false
                collapseProgress = 0
                return
            }
            guard minY < 0 else { return }
            fallbackIsCollapsed = false
        }
        collapseProgress = progress
    }

    private var pullDistance: CGFloat {
        guard latestMinY.isFinite else { return 0 }
        return max(latestMinY, 0)
    }

}

struct NativeRootCompactTitle: View {
    let title: String
    let subtitle: String?
    let collapseProgress: CGFloat

    init(_ title: String, subtitle: String? = nil, collapseProgress: CGFloat) {
        self.title = title
        self.subtitle = subtitle
        self.collapseProgress = collapseProgress
    }

    static func shouldRender(collapseProgress: CGFloat) -> Bool {
        NativeRootHeaderVisibility.usesCompactSemantics(
            collapseProgress: collapseProgress
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .opacity(
                NativeRootHeaderVisibility.compactOpacity(
                    collapseProgress: collapseProgress
                )
            )
            .accessibilityHidden(
                !NativeRootHeaderVisibility.usesCompactSemantics(
                    collapseProgress: collapseProgress
                )
            )
    }
}

@available(iOS 16.0, *)
struct HomeNativeView: View {
    @ObservedObject private var store: HomeFeedNativeStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeChannelIsActive) private var isActiveChannel
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @State private var observedScrollToTopRequest: UInt
    @State private var lastHiddenSearchEntryTarget: NativeHomeContentScrollTarget?
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
        _observedScrollToTopRequest = State(initialValue: scrollToTopRequest)
        self.scrollToTopRequest = scrollToTopRequest
        self.onOpenSearch = onOpenSearch
        self.onOpen = onOpen
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Color.clear
                    .frame(height: 0)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .accessibilityHidden(true)
                    .id(NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .recommendation))

                if let onOpenSearch {
                    NativeHomeGlobalSearchEntry(action: onOpenSearch)
                }

                if store.items.isEmpty, store.isLoading {
                    HStack { Spacer(); ProgressView("正在加载推荐"); Spacer() }
                        .listRowSeparator(.hidden)
                        .id(NativeHomeContentScrollTarget.recommendationStatus)
                }

                ForEach(visibleItems) { item in
                    FeedItemRow(item: item, showsThumbnail: true) { route in
                        store.opened(item)
                        onOpen(route)
                    }
                    .id(NativeHomeContentScrollTarget.recommendation(item.id))
                    .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                }

                if let message = store.errorMessage {
                    FeedRetryRow(message: message) { Task { await store.retry() } }
                        .id(NativeHomeContentScrollTarget.recommendationStatus)
                } else if store.hasNextPage {
                    let taskID = NativeChannelTaskIdentity(
                        isActive: isActiveChannel,
                        value: store.nextPageLoadID
                    )
                    NativeFeedPaginationLoadingRow(title: "正在加载更多推荐")
                        .listRowSeparator(.hidden)
                        .id(NativeHomeContentScrollTarget.recommendationStatus)
                        .task(id: taskID) {
                            guard taskID.isActive,
                                  taskID.value == store.nextPageLoadID
                            else { return }
                            await store.loadMore()
                        }
                } else if visibleItems.isEmpty, !store.isLoading {
                    Label("暂无推荐", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                        .id(NativeHomeContentScrollTarget.recommendationStatus)
                }
            }
            .listStyle(.plain)
            .nativeHomeFeedListLayout()
            .refreshable {
                guard isActiveChannel else { return }
                let outcome = await store.refresh(intent: .pull)
                if outcome == .ignored {
                    hapticFeedback(.refreshIgnored)
                }
            }
            .onAppear {
                // A request token records an action that already happened. Returning
                // from a pushed answer must not replay it and destroy List's retained
                // scroll position. New requests are handled by onChange below.
                observedScrollToTopRequest = scrollToTopRequest
                hideInitialSearchEntryIfNeeded(proxy)
            }
            .onChange(of: firstContentScrollTarget) { _ in
                hideInitialSearchEntryIfNeeded(proxy)
            }
            .onChange(of: isActiveChannel) { isActive in
                if isActive {
                    hideInitialSearchEntryIfNeeded(proxy)
                }
            }
            .onChange(of: scrollToTopRequest) { newRequest in
                let shouldScroll = NativeScrollToTopRequestPolicy.shouldHandleChange(
                    previousRequest: observedScrollToTopRequest,
                    newRequest: newRequest
                )
                observedScrollToTopRequest = newRequest
                if shouldScroll {
                    scrollToTop(proxy, animated: true)
                }
            }
            .onChange(of: store.refreshFeedbackSequence) { _ in
                guard isActiveChannel else { return }
                hapticFeedback(.refreshSucceeded)
            }
            .task(id: isActiveChannel) {
                guard isActiveChannel else { return }
                await store.loadInitialIfNeeded()
            }
        }
        .accessibilityIdentifier("home_native")
    }

    private var visibleItems: [FeedItemDTO] {
        FeedQuestionAuthorVisibilityPolicy.visibleItems(
            from: store.items,
            blockedMemberIDs: questionAuthorBlocklist.blockedMemberIDs
        )
    }

    private var firstContentScrollTarget: NativeHomeContentScrollTarget? {
        visibleItems.first.map { .recommendation($0.id) } ?? .recommendationStatus
    }

    private func scrollToTop(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation {
                    if let firstContentScrollTarget {
                        proxy.scrollTo(firstContentScrollTarget, anchor: .top)
                    } else {
                        proxy.scrollTo(
                            NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .recommendation),
                            anchor: .top
                        )
                    }
                }
            } else if let firstContentScrollTarget {
                proxy.scrollTo(firstContentScrollTarget, anchor: .top)
            } else {
                proxy.scrollTo(
                    NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .recommendation),
                    anchor: .top
                )
            }
        }
    }

    private func hideInitialSearchEntryIfNeeded(_ proxy: ScrollViewProxy) {
        NativeHomeSearchEntryScrollController.hideIfNeeded(
            in: proxy,
            target: firstContentScrollTarget,
            isActive: isActiveChannel,
            lastHiddenTarget: $lastHiddenSearchEntryTarget
        )
    }
}

struct FollowNativeView: View {
    @ObservedObject private var store: FollowNativeStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeChannelIsActive) private var isActiveChannel
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @State private var observedScrollToTopRequest: UInt
    @State private var lastHiddenSearchEntryTarget: NativeHomeContentScrollTarget?
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
        _observedScrollToTopRequest = State(initialValue: scrollToTopRequest)
        self.scrollToTopRequest = scrollToTopRequest
        self.onOpenSearch = onOpenSearch
        self.onOpen = onOpen
        self.onOpenPerson = onOpenPerson
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Color.clear
                    .frame(height: 0)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .accessibilityHidden(true)
                    .id(NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .following))

                if let onOpenSearch {
                    NativeHomeGlobalSearchEntry(action: onOpenSearch)
                }

                recentUsers

                if store.moments.items.isEmpty, store.moments.isLoading {
                    HStack { Spacer(); ProgressView("正在加载关注内容"); Spacer() }
                        .listRowSeparator(.hidden)
                        .id(NativeHomeContentScrollTarget.followingStatus)
                }

                ForEach(visibleItems) { item in
                    FeedItemRow(item: item, showsThumbnail: true, onOpen: onOpen)
                        .id(NativeHomeContentScrollTarget.following(item.id))
                        .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                }

                if let message = store.moments.errorMessage {
                    FeedRetryRow(message: message) {
                        Task { await store.retry(section: .moments) }
                    }
                    .id(NativeHomeContentScrollTarget.followingStatus)
                } else if store.moments.hasNextPage {
                    let taskID = NativeChannelTaskIdentity(
                        isActive: isActiveChannel,
                        value: store.moments.nextPageLoadID
                    )
                    NativeFeedPaginationLoadingRow(title: "正在加载更多关注内容")
                        .listRowSeparator(.hidden)
                        .id(NativeHomeContentScrollTarget.followingStatus)
                        .task(id: taskID) {
                            guard taskID.isActive,
                                  taskID.value == store.moments.nextPageLoadID
                            else { return }
                            await store.loadMore(section: .moments)
                        }
                } else if visibleItems.isEmpty, !store.moments.isLoading {
                    Label("暂无关注内容", systemImage: "person.2")
                        .foregroundStyle(.secondary)
                        .id(NativeHomeContentScrollTarget.followingStatus)
                }
            }
            .listStyle(.plain)
            .nativeHomeFeedListLayout()
            .refreshable {
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
            .onAppear {
                observedScrollToTopRequest = scrollToTopRequest
                hideInitialSearchEntryIfNeeded(proxy)
            }
            .onChange(of: scrollToTopRequest) { newRequest in
                let shouldScroll = NativeScrollToTopRequestPolicy.shouldHandleChange(
                    previousRequest: observedScrollToTopRequest,
                    newRequest: newRequest
                )
                observedScrollToTopRequest = newRequest
                if shouldScroll { scrollToTop(proxy, animated: true) }
            }
            .onChange(of: firstContentScrollTarget) { _ in
                hideInitialSearchEntryIfNeeded(proxy)
            }
            .onChange(of: isActiveChannel) { isActive in
                if isActive {
                    hideInitialSearchEntryIfNeeded(proxy)
                }
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

    private var firstContentScrollTarget: NativeHomeContentScrollTarget? {
        if !store.recentUsers.isEmpty || store.recentUsersErrorMessage != nil {
            return .followingRecentUsers
        }
        return visibleItems.first.map { .following($0.id) } ?? .followingStatus
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
                .nativeChannelSwipeExclusion()
            }
            .id(NativeHomeContentScrollTarget.followingRecentUsers)
        } else if let error = store.recentUsersErrorMessage {
            Section("最近动态") {
                FeedRetryRow(message: error) { Task { await store.reloadRecentUsers() } }
            }
            .id(NativeHomeContentScrollTarget.followingRecentUsers)
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation {
                    if let firstContentScrollTarget {
                        proxy.scrollTo(firstContentScrollTarget, anchor: .top)
                    } else {
                        proxy.scrollTo(
                            NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .following),
                            anchor: .top
                        )
                    }
                }
            } else if let firstContentScrollTarget {
                proxy.scrollTo(firstContentScrollTarget, anchor: .top)
            } else {
                proxy.scrollTo(
                    NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .following),
                    anchor: .top
                )
            }
        }
    }

    private func hideInitialSearchEntryIfNeeded(_ proxy: ScrollViewProxy) {
        NativeHomeSearchEntryScrollController.hideIfNeeded(
            in: proxy,
            target: firstContentScrollTarget,
            isActive: isActiveChannel,
            lastHiddenTarget: $lastHiddenSearchEntryTarget
        )
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
