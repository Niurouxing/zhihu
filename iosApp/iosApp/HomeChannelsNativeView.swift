import SwiftUI
import UIKit

struct HomeChannelRefreshPresentation: Equatable {
    let metadata: FeedChannelRefreshMetadata
    let isRefreshing: Bool

    func statusText(now: Date) -> String {
        HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: metadata.lastSuccessfulRefreshAt,
            isRefreshing: isRefreshing,
            now: now
        )
    }
}

struct HomeChannelRefreshPresentationMap: Equatable {
    let recommendation: HomeChannelRefreshPresentation
    let following: HomeChannelRefreshPresentation
    let hot: HomeChannelRefreshPresentation
    let daily: HomeChannelRefreshPresentation

    func presentation(for channel: HomeChannel) -> HomeChannelRefreshPresentation {
        switch channel {
        case .recommendation: return recommendation
        case .following: return following
        case .hot: return hot
        case .daily: return daily
        }
    }
}

@available(iOS 16.0, *)
@MainActor
struct HomeChannelsNativeView: View {
    @Binding var selectedChannelID: HomeChannel.ID

    @ObservedObject private var recommendationStore: HomeFeedNativeStore
    @ObservedObject private var followingStore: FollowNativeStore
    @ObservedObject private var hotStore: HotFeedStore
    @ObservedObject private var dailyStore: DailyNativeStore

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastSelectedChannelID: HomeChannel.ID
    @State private var scrollToTopRequests: [HomeChannel: UInt] = [:]
    @State private var idleRefreshTask: Task<Void, Never>?
    @State private var doubleTapRefreshTask: Task<Void, Never>?
    @State private var doubleTapRefreshGeneration: UInt = 0
    @State private var wasOperationallyVisible = false
    @State private var refreshStatusNow = Date()
    @State private var isTopBarVisible = true

    let isOperationallyVisible: Bool
    let doubleTapRefreshRequest: UInt
    let notificationUnreadCount: Int
    let accountAvatarURL: URL?
    let onOpenFeed: (FeedItemRoute) -> Void
    let onOpenPerson: (PersonRoutePayload) -> Void
    let onOpenDaily: (DailyStoryDestination) -> Void
    let onOpenAccount: () -> Void
    let onOpenSearch: () -> Void
    let onOpenCreation: () -> Void
    let onOpenNotifications: () -> Void

    init(
        selectedChannelID: Binding<HomeChannel.ID>,
        recommendationStore: HomeFeedNativeStore,
        followingStore: FollowNativeStore,
        hotStore: HotFeedStore,
        dailyStore: DailyNativeStore,
        doubleTapRefreshRequest: UInt,
        isOperationallyVisible: Bool,
        notificationUnreadCount: Int,
        accountAvatarURL: URL?,
        onOpenFeed: @escaping (FeedItemRoute) -> Void,
        onOpenPerson: @escaping (PersonRoutePayload) -> Void,
        onOpenDaily: @escaping (DailyStoryDestination) -> Void,
        onOpenAccount: @escaping () -> Void,
        onOpenSearch: @escaping () -> Void,
        onOpenCreation: @escaping () -> Void,
        onOpenNotifications: @escaping () -> Void
    ) {
        _selectedChannelID = selectedChannelID
        _recommendationStore = ObservedObject(wrappedValue: recommendationStore)
        _followingStore = ObservedObject(wrappedValue: followingStore)
        _hotStore = ObservedObject(wrappedValue: hotStore)
        _dailyStore = ObservedObject(wrappedValue: dailyStore)
        _lastSelectedChannelID = State(initialValue: selectedChannelID.wrappedValue)
        self.doubleTapRefreshRequest = doubleTapRefreshRequest
        self.isOperationallyVisible = isOperationallyVisible
        self.notificationUnreadCount = notificationUnreadCount
        self.accountAvatarURL = accountAvatarURL
        self.onOpenFeed = onOpenFeed
        self.onOpenPerson = onOpenPerson
        self.onOpenDaily = onOpenDaily
        self.onOpenAccount = onOpenAccount
        self.onOpenSearch = onOpenSearch
        self.onOpenCreation = onOpenCreation
        self.onOpenNotifications = onOpenNotifications
    }

    var body: some View {
        ZStack(alignment: .top) {
            NativeChannelSwitcher(
                channels: HomeChannel.allCases,
                selection: $selectedChannelID,
                isEnabled: isEffectivelyVisible
            ) { channel in
                channelContent(channel)
            }

            homeTopBar
                .offset(y: isTopBarVisible ? 0 : -NativeHomeTopChromeLayout.height)
                .opacity(isTopBarVisible ? 1 : 0)
                .allowsHitTesting(isTopBarVisible)
                .zIndex(10)
        }
        .environment(\.nativeHomeTopBarScrollIntentAction) { intent in
            handleTopBarScrollIntent(intent)
        }
        .navigationTitle(selectedChannel.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            lastSelectedChannelID = selectedChannelID
            setTopBarVisible(true, animated: false)
            synchronizeOperationalVisibility()
        }
        .onDisappear {
            transitionOperationalVisibility(to: false)
            cancelDoubleTapRefresh()
        }
        .onChange(of: selectedChannelID) { newChannelID in
            guard newChannelID != lastSelectedChannelID else { return }
            cancelDoubleTapRefresh()
            if wasOperationallyVisible,
               let previous = HomeChannel(rawValue: lastSelectedChannelID) {
                recordLastViewed(for: previous)
            }
            lastSelectedChannelID = newChannelID
            setTopBarVisible(true, animated: true)
            if wasOperationallyVisible {
                scheduleIdleRefreshIfNeeded(for: selectedChannel)
            }
        }
        .onChange(of: isOperationallyVisible) { _ in
            synchronizeOperationalVisibility()
            if isOperationallyVisible {
                setTopBarVisible(true, animated: false)
            }
        }
        .onChange(of: doubleTapRefreshRequest) { request in
            guard request > 0 else { return }
            scheduleDoubleTapRefresh()
        }
        .onChange(of: scenePhase) { _ in
            synchronizeOperationalVisibility()
        }
        .task {
            await runRefreshStatusClock()
        }
        .accessibilityIdentifier("home_channels_native")
    }

    private var homeTopBar: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            HStack(spacing: 12) {
                Button(action: onOpenAccount) {
                    accountToolbarLabel
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
                .accessibilityLabel("账号")
                .accessibilityIdentifier("home_account_entry")

                Spacer(minLength: 52)

                HStack(spacing: 2) {
                    homeToolbarButton(.creation)
                        .frame(width: 42, height: 42)
                    homeToolbarButton(.notifications)
                        .frame(width: 42, height: 42)
                }
                .padding(.horizontal, 3)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.horizontal, 12)

            channelMenu
        }
        .frame(height: NativeHomeTopChromeLayout.height)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.28)
        }
        .accessibilityIdentifier("home_top_chrome")
    }

    private var channelMenu: some View {
        Menu {
            ForEach(HomeChannel.allCases) { channel in
                Button {
                    selectChannel(channel)
                } label: {
                    Label(
                        channel.title,
                        systemImage: channel == selectedChannel
                            ? "checkmark"
                            : channel.systemImage
                    )
                }
                .disabled(channel == selectedChannel)
            }

            Divider()

            Text(
                currentRefreshPresentations
                    .presentation(for: selectedChannel)
                    .statusText(now: refreshStatusNow)
            )
        } label: {
            HStack(spacing: 6) {
                Text(selectedChannel.title)
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("首页频道，当前为\(selectedChannel.title)")
        .accessibilityHint("向下轻拉可显示搜索")
        .accessibilityAction(named: Text("搜索知乎"), onOpenSearch)
        .accessibilityIdentifier("home_channel_menu")
    }

    private var accountToolbarLabel: some View {
        AsyncImage(url: accountAvatarURL) { phase in
            if case let .success(image) = phase {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .contentShape(Circle())
    }

    @ViewBuilder
    private func channelContent(_ channel: HomeChannel) -> some View {
        switch channel {
        case .recommendation:
            HomeNativeView(
                store: recommendationStore,
                scrollToTopRequest: scrollRequest(for: channel),
                onOpenSearch: onOpenSearch,
                onOpen: onOpenFeed
            )
        case .following:
            FollowNativeView(
                store: followingStore,
                scrollToTopRequest: scrollRequest(for: channel),
                onOpenSearch: onOpenSearch,
                onOpen: onOpenFeed,
                onOpenPerson: onOpenPerson
            )
        case .hot:
            HotListNativeView(
                store: hotStore,
                scrollToTopRequest: scrollRequest(for: channel),
                onOpenSearch: onOpenSearch,
                onOpen: onOpenFeed
            )
        case .daily:
            DailyNativeView(
                store: dailyStore,
                scrollToTopRequest: scrollRequest(for: channel),
                onOpenSearch: onOpenSearch,
                onOpen: onOpenDaily
            )
        }
    }

    @ViewBuilder
    private func homeToolbarButton(_ control: HomeTopBarControl) -> some View {
        switch control {
        case .creation:
            Button(action: onOpenCreation) {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("创作")
            .accessibilityIdentifier("home_creation_entry")

        case .notifications:
            let presentation = HomeNotificationIndicatorPresentation(
                unreadCount: notificationUnreadCount
            )
            Button(action: onOpenNotifications) {
                Image(systemName: "bell")
                    .overlay(alignment: .topTrailing) {
                        if presentation.showsDot {
                            Circle()
                                .fill(.red)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                                .offset(x: 3, y: -2)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(presentation.accessibilityValue)
            .accessibilityIdentifier("home_notifications_entry")
        }
    }

    private func selectChannel(_ channel: HomeChannel) {
        guard selectedChannelID != channel.id else { return }
        selectedChannelID = channel.id
        hapticFeedback(.selection)
    }

    private var selectedChannel: HomeChannel {
        HomeChannel(rawValue: selectedChannelID) ?? .recommendation
    }

    private func handleTopBarScrollIntent(_ intent: NativeHomeTopBarScrollIntent) {
        guard isEffectivelyVisible else { return }
        setTopBarVisible(intent == .show, animated: true)
    }

    private func setTopBarVisible(_ isVisible: Bool, animated: Bool) {
        guard isTopBarVisible != isVisible else { return }
        if animated, !reduceMotion {
            withAnimation(.easeOut(duration: 0.17)) {
                isTopBarVisible = isVisible
            }
        } else {
            isTopBarVisible = isVisible
        }
    }

    private var isEffectivelyVisible: Bool {
        isOperationallyVisible && scenePhase == .active
    }

    private func scrollRequest(for channel: HomeChannel) -> UInt {
        scrollToTopRequests[channel, default: 0]
    }

    private func scheduleIdleRefreshIfNeeded(for channel: HomeChannel) {
        idleRefreshTask?.cancel()
        idleRefreshTask = Task { @MainActor in
            guard isEffectivelyVisible,
                  selectedChannelID == channel.id,
                  needsRefreshAfterIdle(channel)
            else { return }
            if channel == .recommendation, recommendationStore.isLoading {
                return
            }

            scrollToTopRequests[channel, default: 0] &+= 1
            do {
                // Match the confirmed MNGA sequence: allow the scroll-to-top animation
                // to settle before replacing the first page.
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  isEffectivelyVisible,
                  selectedChannelID == channel.id,
                  needsRefreshAfterIdle(channel)
            else { return }
            if channel == .recommendation {
                _ = await recommendationStore.refresh(intent: .automatic)
                return
            }
            guard await waitUntilIdle(for: channel) else { return }
            let previousSuccessfulRefresh = successfulRefreshDate(for: channel)
            await refresh(channel)
            guard !Task.isCancelled,
                  selectedChannelID == channel.id,
                  NativeRefreshHapticPolicy.shouldEmit(
                    previousSuccessfulRefreshAt: previousSuccessfulRefresh,
                    currentSuccessfulRefreshAt: successfulRefreshDate(for: channel)
                  )
            else { return }
            hapticFeedback(.refreshSucceeded)
        }
    }

    private func scheduleDoubleTapRefresh() {
        guard doubleTapRefreshTask == nil, isEffectivelyVisible else { return }
        idleRefreshTask?.cancel()
        let channel = selectedChannel
        doubleTapRefreshGeneration &+= 1
        let generation = doubleTapRefreshGeneration
        scrollToTopRequests[channel, default: 0] &+= 1

        doubleTapRefreshTask = Task { @MainActor in
            defer {
                if generation == doubleTapRefreshGeneration {
                    doubleTapRefreshTask = nil
                }
            }
            if channel == .recommendation {
                guard !Task.isCancelled,
                      generation == doubleTapRefreshGeneration,
                      isEffectivelyVisible,
                      selectedChannelID == channel.id
                else { return }
                _ = await recommendationStore.refresh(intent: .returnToTop)
                return
            }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  generation == doubleTapRefreshGeneration,
                  isEffectivelyVisible,
                  selectedChannelID == channel.id,
                  await waitUntilIdle(for: channel)
            else { return }
            let previousSuccessfulRefresh = successfulRefreshDate(for: channel)
            await refresh(channel)
            guard !Task.isCancelled,
                  generation == doubleTapRefreshGeneration,
                  selectedChannelID == channel.id,
                  NativeRefreshHapticPolicy.shouldEmit(
                    previousSuccessfulRefreshAt: previousSuccessfulRefresh,
                    currentSuccessfulRefreshAt: successfulRefreshDate(for: channel)
                  )
            else { return }
            hapticFeedback(.refreshSucceeded)
        }
    }

    private func cancelDoubleTapRefresh() {
        doubleTapRefreshGeneration &+= 1
        doubleTapRefreshTask?.cancel()
        doubleTapRefreshTask = nil
    }

    private func synchronizeOperationalVisibility() {
        transitionOperationalVisibility(to: isEffectivelyVisible)
    }

    private func transitionOperationalVisibility(to isVisible: Bool) {
        guard isVisible != wasOperationallyVisible else { return }
        let wasVisible = wasOperationallyVisible
        wasOperationallyVisible = isVisible
        idleRefreshTask?.cancel()
        if !isVisible { cancelDoubleTapRefresh() }
        if wasVisible {
            recordLastViewed(for: selectedChannel)
        }
        if isVisible {
            setTopBarVisible(true, animated: false)
            scheduleIdleRefreshIfNeeded(for: selectedChannel)
        }
    }

    private func waitUntilIdle(for channel: HomeChannel) async -> Bool {
        // A pagination request may still be unwinding after the channel becomes active.
        // Wait for at most five seconds so automatic refresh never spins or waits forever.
        for _ in 0..<50 {
            guard !Task.isCancelled,
                  isEffectivelyVisible,
                  selectedChannelID == channel.id
            else { return false }
            if !isLoading(channel) { return true }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return false
            }
        }
        return false
    }

    private func isLoading(_ channel: HomeChannel) -> Bool {
        switch channel {
        case .recommendation: return recommendationStore.isLoading
        case .following: return followingStore.isMomentsLoading
        case .hot: return hotStore.isLoading
        case .daily: return dailyStore.isLoading || dailyStore.isLoadingMore
        }
    }

    private func recordLastViewed(for channel: HomeChannel) {
        switch channel {
        case .recommendation: recommendationStore.recordLastViewed()
        case .following: followingStore.recordLastViewed()
        case .hot: hotStore.recordLastViewed()
        case .daily: dailyStore.recordLastViewed()
        }
    }

    private func needsRefreshAfterIdle(_ channel: HomeChannel) -> Bool {
        switch channel {
        case .recommendation: return recommendationStore.needsRefreshAfterIdle()
        case .following: return followingStore.needsRefreshAfterIdle()
        case .hot: return hotStore.needsRefreshAfterIdle()
        case .daily: return dailyStore.needsRefreshAfterIdle()
        }
    }

    private func refresh(_ channel: HomeChannel) async {
        switch channel {
        case .recommendation: await recommendationStore.refresh()
        case .following: await followingStore.refresh(section: .moments)
        case .hot: await hotStore.refresh()
        case .daily: await dailyStore.refresh()
        }
    }

    private func successfulRefreshDate(for channel: HomeChannel) -> Date? {
        switch channel {
        case .recommendation: return recommendationStore.refreshMetadata.lastSuccessfulRefreshAt
        case .following: return followingStore.refreshMetadata.lastSuccessfulRefreshAt
        case .hot: return hotStore.refreshMetadata.lastSuccessfulRefreshAt
        case .daily: return dailyStore.refreshMetadata.lastSuccessfulRefreshAt
        }
    }

    private var currentRefreshPresentations: HomeChannelRefreshPresentationMap {
        HomeChannelRefreshPresentationMap(
            recommendation: HomeChannelRefreshPresentation(
                metadata: recommendationStore.refreshMetadata,
                isRefreshing: recommendationStore.isRefreshing
            ),
            following: HomeChannelRefreshPresentation(
                metadata: followingStore.refreshMetadata,
                isRefreshing: followingStore.isMomentsRefreshing
            ),
            hot: HomeChannelRefreshPresentation(
                metadata: hotStore.refreshMetadata,
                isRefreshing: hotStore.isRefreshing
            ),
            daily: HomeChannelRefreshPresentation(
                metadata: dailyStore.refreshMetadata,
                isRefreshing: dailyStore.isRefreshing
            )
        )
    }

    private func runRefreshStatusClock() async {
        refreshStatusNow = Date()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                return
            }
            refreshStatusNow = Date()
        }
    }

}

enum HomeTopBarControl: String, CaseIterable, Identifiable {
    case creation
    case notifications

    var id: String { rawValue }
    static let visibleControls: [HomeTopBarControl] = [.creation, .notifications]
}

struct HomeNotificationIndicatorPresentation: Equatable {
    let unreadCount: Int

    init(unreadCount: Int) {
        self.unreadCount = max(0, unreadCount)
    }

    var showsDot: Bool { unreadCount > 0 }
    var accessibilityLabel: String {
        unreadCount > 0 ? "通知，\(unreadCount) 条未读" : "通知"
    }
    var accessibilityValue: String {
        unreadCount > 0 ? "\(unreadCount) 条未读" : "无未读通知"
    }
}

enum HomeChannelRefreshStatusText {
    static func text(
        lastSuccessfulRefreshAt: Date?,
        isRefreshing: Bool,
        now: Date
    ) -> String {
        if isRefreshing { return "更新中…" }
        guard let lastSuccessfulRefreshAt else { return "尚未更新" }

        let elapsed = max(0, now.timeIntervalSince(lastSuccessfulRefreshAt))
        if elapsed < 60 { return "刚刚更新" }
        if elapsed < 60 * 60 {
            return "\(max(1, Int(elapsed / 60))) 分钟前更新"
        }
        return "\(max(1, Int(elapsed / (60 * 60)))) 小时前更新"
    }
}
