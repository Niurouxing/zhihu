import SwiftUI

@available(iOS 16.0, *)
struct HotListNativeView: View {
    @ObservedObject private var store: HotFeedStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeChannelIsActive) private var isActiveChannel
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @State private var observedScrollToTopRequest: UInt
    @State private var hasAlignedInitialTop = false
    @State private var isInitialTopAlignmentScheduled = false
    @State private var initialTopAlignmentAttempts = 0
    @State private var isPullRefreshInFlight = false
    @State private var settledSearchDrawerTarget: NativeHomeSearchDrawerSnapTarget = .collapsed
    @State private var scrollExtentHeight: CGFloat?
    @State private var latestNormalizedOffset = CGFloat.nan
    private let scrollToTopRequest: UInt
    private let onOpenSearch: (() -> Void)?
    private let onOpen: (FeedItemRoute) -> Void

    init(
        store: HotFeedStore,
        scrollToTopRequest: UInt = 0,
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
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                NativeHomeFeedScrollView {
                if let onOpenSearch {
                    NativeHomeRefreshRevealSpacer(
                        channel: .hot,
                        isRefreshing: isRefreshInFlight
                    )
                    NativeHomePullSearchDrawer(
                        channel: .hot,
                        isRevealed: NativeHomeSearchDrawerVisibilityPolicy.isRevealed(
                            normalizedOffset: latestNormalizedOffset
                        ),
                        action: onOpenSearch
                    )
                    .opacity(hasAlignedInitialTop ? 1 : 0)
                }

                if store.items.isEmpty, store.isLoading {
                    HStack {
                        Spacer()
                        ProgressView("正在加载热榜")
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                    .id(NativeHomeContentScrollTarget.hotStatus)
                }

                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    FeedItemRow(
                        item: item,
                        showsThumbnail: false,
                        rank: index + 1,
                        onOpen: onOpen
                    )
                    .id(NativeHomeContentScrollTarget.hot(item.id))
                    .nativeFeedCardItemLayout()
                }

                if let errorMessage = store.errorMessage {
                    FeedRetryRow(message: errorMessage) {
                        Task { await store.retry() }
                    }
                    .id(NativeHomeContentScrollTarget.hotStatus)
                    .nativeFeedCardItemLayout()
                } else if store.canLoadNextPage {
                    let taskID = NativeChannelTaskIdentity(
                        isActive: isActiveChannel,
                        value: store.nextPageLoadID
                    )
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                    .id(NativeHomeContentScrollTarget.hotStatus)
                    .task(id: taskID) {
                        guard taskID.isActive,
                              taskID.value == store.nextPageLoadID
                        else { return }
                        await store.loadNextPage()
                    }
                } else if visibleItems.isEmpty, !store.isLoading {
                    Label("暂无热榜", systemImage: "flame")
                        .foregroundStyle(.secondary)
                        .id(NativeHomeContentScrollTarget.hotStatus)
                }

                    NativeHomeMinimumScrollExtent(
                        height: scrollExtentHeight ?? viewport.size.height
                    )
                }
                .nativeHomeTwoStagePullGeometry(
                    extentHeight: $scrollExtentHeight,
                    latestNormalizedOffset: $latestNormalizedOffset,
                    initialExtentHeight: viewport.size.height,
                    isActive: isActiveChannel,
                    isRefreshing: isRefreshInFlight,
                    isReady: hasAlignedInitialTop
                ) { offset, reason in
                    settleSearchDrawer(at: offset, reason: reason, proxy: proxy)
                }
                .nativeHomeTopBarScrollTracking(isActive: isActiveChannel)
                .refreshable {
                    guard isActiveChannel else { return }
                    settledSearchDrawerTarget = .revealed
                    isPullRefreshInFlight = true
                    defer { isPullRefreshInFlight = false }
                    let previousSuccessfulRefresh = store.refreshMetadata.lastSuccessfulRefreshAt
                    await store.refresh()
                    if !Task.isCancelled,
                       NativeRefreshHapticPolicy.shouldEmit(
                        previousSuccessfulRefreshAt: previousSuccessfulRefresh,
                        currentSuccessfulRefreshAt: store.refreshMetadata.lastSuccessfulRefreshAt
                       ) {
                        hapticFeedback(.refreshSucceeded)
                    }
                }
                .allowsHitTesting(hasAlignedInitialTop)
                .onAppear {
                    observedScrollToTopRequest = scrollToTopRequest
                    alignInitialTopIfNeeded(proxy)
                }
                .onChange(of: scrollExtentHeight) { newHeight in
                    if newHeight != nil {
                        alignInitialTopIfNeeded(proxy)
                    }
                }
                .onChange(of: isRefreshInFlight) { refreshing in
                    if refreshing {
                        isInitialTopAlignmentScheduled = false
                    } else {
                        alignInitialTopIfNeeded(proxy)
                    }
                }
                .onChange(of: scrollToTopRequest) { newRequest in
                    let shouldScroll = NativeScrollToTopRequestPolicy.shouldHandleChange(
                        previousRequest: observedScrollToTopRequest,
                        newRequest: newRequest
                    )
                    observedScrollToTopRequest = newRequest
                    if shouldScroll { scrollToTop(proxy, animated: true) }
                }
                .task(id: isActiveChannel) {
                    guard isActiveChannel else { return }
                    await store.loadInitialIfNeeded()
                }
            }
        }
        .accessibilityIdentifier("hot_list")
    }

    private func settleSearchDrawer(
        at normalizedOffset: CGFloat,
        reason: NativeHomeSearchDrawerSettleReason,
        proxy: ScrollViewProxy
    ) {
        guard isActiveChannel else { return }
        let decision = NativeHomeSearchDrawerSettlementPolicy.decision(
            previousTarget: settledSearchDrawerTarget,
            normalizedOffset: normalizedOffset,
            reason: reason,
            isRefreshing: isRefreshInFlight
        )
        settledSearchDrawerTarget = decision.settledTarget
        guard let target = decision.scrollTarget else { return }
        let anchor: NativeHomeListScrollAnchor
        switch target {
        case .revealed:
            anchor = .revealedTop(.hot)
        case .collapsed:
            anchor = .collapsedTop(.hot)
        }
        let targetOffset = target == .revealed
            ? 0
            : NativeHomeTopChromeLayout.searchDrawerHeight
        guard abs(normalizedOffset - targetOffset)
            > NativeHomeSearchDrawerSnapPolicy.settledTolerance
        else { return }
        switch reason {
        case .interactionEnded:
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(anchor, anchor: .top)
            }
        case .layoutChanged:
            DispatchQueue.main.async {
                guard isActiveChannel, !isRefreshInFlight else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
        }
    }

    private var visibleItems: [FeedItemDTO] {
        FeedQuestionAuthorVisibilityPolicy.visibleItems(
            from: store.items,
            blockedMemberIDs: questionAuthorBlocklist.blockedMemberIDs
        )
    }

    private var pullDrawerAnchor: NativeHomeListScrollAnchor {
        .collapsedTop(.hot)
    }

    private var isRefreshInFlight: Bool {
        isPullRefreshInFlight || store.isRefreshing
    }

    private func scrollToTop(_ proxy: ScrollViewProxy, animated: Bool) {
        settledSearchDrawerTarget = .collapsed
        DispatchQueue.main.async {
            if animated {
                withAnimation {
                    proxy.scrollTo(pullDrawerAnchor, anchor: .top)
                }
            } else {
                proxy.scrollTo(pullDrawerAnchor, anchor: .top)
            }
        }
    }

    private func alignInitialTopIfNeeded(_ proxy: ScrollViewProxy) {
        guard !hasAlignedInitialTop, !isInitialTopAlignmentScheduled else { return }
        guard onOpenSearch != nil else {
            finishInitialTopAlignment()
            return
        }
        guard !isRefreshInFlight else { return }
        guard NativeHomeInitialTopAlignmentPolicy.canAttempt(
            after: initialTopAlignmentAttempts
        ) else {
            finishInitialTopAlignment()
            return
        }
        initialTopAlignmentAttempts += 1
        isInitialTopAlignmentScheduled = true
        DispatchQueue.main.async {
            guard !hasAlignedInitialTop,
                  isInitialTopAlignmentScheduled,
                  !isRefreshInFlight
            else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(pullDrawerAnchor, anchor: .top)
            }
            validateInitialTopAlignment(proxy)
        }
    }

    private func validateInitialTopAlignment(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NativeHomeInitialTopAlignmentPolicy.validationDelay
        ) {
            guard !hasAlignedInitialTop, isInitialTopAlignmentScheduled else { return }
            isInitialTopAlignmentScheduled = false
            guard !isRefreshInFlight else { return }
            if NativeHomeInitialTopAlignmentPolicy.isAligned(
                normalizedOffset: latestNormalizedOffset
            ) {
                finishInitialTopAlignment()
            } else {
                alignInitialTopIfNeeded(proxy)
            }
        }
    }

    private func finishInitialTopAlignment() {
        hasAlignedInitialTop = true
        isInitialTopAlignmentScheduled = false
    }
}
