import SwiftUI
import UIKit

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
    @State private var wasOperationallyVisible = false
    @State private var areFloatingControlsVisible = true
    @State private var scrollRuntimeActivationRequest: UInt = 0
    @State private var transientChannel: HomeChannel?
    @State private var channelIndicatorDismissTask: Task<Void, Never>?
    @State private var scrollPositionRegistry = NativeHomeScrollPositionRegistry()

    let isOperationallyVisible: Bool
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

            homeFloatingControls
                .offset(y: areFloatingControlsVisible ? 0 : -10)
                .scaleEffect(
                    areFloatingControlsVisible ? 1 : 0.96,
                    anchor: .top
                )
                .opacity(areFloatingControlsVisible ? 1 : 0)
                .allowsHitTesting(areFloatingControlsVisible)
                .zIndex(10)

            if let transientChannel {
                transientChannelIndicator(for: transientChannel)
                    .transition(
                        .scale(scale: 0.94, anchor: .top)
                            .combined(with: .opacity)
                    )
                    .zIndex(20)
            }
        }
        .environment(\.nativeHomeFloatingControlsScrollIntentAction) { event in
            handleFloatingControlsScrollEvent(event)
        }
        .environment(
            \.nativeHomeScrollRuntimeActivationRequest,
            scrollRuntimeActivationRequest
        )
        .environment(\.nativeHomeScrollPositionRegistry, scrollPositionRegistry)
        .navigationTitle(selectedChannel.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            lastSelectedChannelID = selectedChannelID
            synchronizeOperationalVisibility(forceRuntimeActivation: true)
        }
        .onDisappear {
            transitionOperationalVisibility(to: false)
            dismissChannelIndicator(animated: false)
        }
        .onChange(of: selectedChannelID) { _, newChannelID in
            guard newChannelID != lastSelectedChannelID else { return }
            if wasOperationallyVisible,
               let previous = HomeChannel(rawValue: lastSelectedChannelID) {
                recordLastViewed(for: previous)
            }
            lastSelectedChannelID = newChannelID
            if let channel = HomeChannel(rawValue: newChannelID) {
                presentChannelIndicator(channel)
            }
            if wasOperationallyVisible {
                scheduleIdleRefreshIfNeeded(for: selectedChannel)
            }
        }
        .onChange(of: isOperationallyVisible) {
            synchronizeOperationalVisibility()
        }
        .onChange(of: scenePhase) {
            synchronizeOperationalVisibility()
        }
        .accessibilityIdentifier("home_channels_native")
    }

    private var homeFloatingControls: some View {
        HStack(spacing: 12) {
            HomeFloatingSurface(in: Circle()) {
                Button(action: onOpenAccount) {
                    accountToolbarLabel
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .frame(
                    width: NativeHomeFloatingControlsLayout.controlHeight,
                    height: NativeHomeFloatingControlsLayout.controlHeight
                )
                .contentShape(Circle())
                .accessibilityLabel("账号")
                .accessibilityIdentifier("home_account_entry")
            }

            Spacer(minLength: 100)

            HomeFloatingSurface(in: Capsule()) {
                HStack(spacing: 2) {
                    ForEach(HomeFloatingControl.visibleControls) { control in
                        homeFloatingButton(control)
                            .frame(width: 42, height: 42)
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, NativeHomeFloatingControlsLayout.horizontalInset)
        .frame(height: NativeHomeFloatingControlsLayout.height)
        .accessibilityIdentifier("home_floating_controls")
    }

    private func transientChannelIndicator(for channel: HomeChannel) -> some View {
        HStack(spacing: 7) {
            Image(systemName: channel.systemImage)
                .font(.caption.weight(.semibold))
            Text(channel.title)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        .frame(
            maxWidth: .infinity,
            minHeight: NativeHomeFloatingControlsLayout.height,
            alignment: .top
        )
        .padding(.top, 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .id(channel.id)
    }

    private func presentChannelIndicator(_ channel: HomeChannel) {
        channelIndicatorDismissTask?.cancel()
        if reduceMotion {
            transientChannel = channel
        } else {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                transientChannel = channel
            }
        }
        channelIndicatorDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 800_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            dismissChannelIndicator(animated: true)
        }
    }

    private func dismissChannelIndicator(animated: Bool) {
        channelIndicatorDismissTask?.cancel()
        channelIndicatorDismissTask = nil
        guard transientChannel != nil else { return }
        if animated, !reduceMotion {
            withAnimation(.easeOut(duration: 0.16)) {
                transientChannel = nil
            }
        } else {
            transientChannel = nil
        }
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
    private func homeFloatingButton(_ control: HomeFloatingControl) -> some View {
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

    private var selectedChannel: HomeChannel {
        HomeChannel(rawValue: selectedChannelID) ?? .recommendation
    }

    private func handleFloatingControlsScrollEvent(
        _ event: NativeHomeFloatingControlsScrollEvent
    ) {
        guard isEffectivelyVisible, event.channel == selectedChannel else { return }
        setFloatingControlsVisible(
            event.intent == .show,
            animated: true
        )
    }

    private func setFloatingControlsVisible(
        _ isVisible: Bool,
        animated: Bool
    ) {
        guard areFloatingControlsVisible != isVisible else { return }
        if animated, !reduceMotion {
            withAnimation(.easeOut(duration: 0.17)) {
                areFloatingControlsVisible = isVisible
            }
        } else {
            areFloatingControlsVisible = isVisible
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

    private func synchronizeOperationalVisibility(
        forceRuntimeActivation: Bool = false
    ) {
        transitionOperationalVisibility(
            to: isEffectivelyVisible,
            forceRuntimeActivation: forceRuntimeActivation
        )
    }

    private func transitionOperationalVisibility(
        to isVisible: Bool,
        forceRuntimeActivation: Bool = false
    ) {
        guard isVisible != wasOperationallyVisible else {
            if isVisible, forceRuntimeActivation {
                requestScrollRuntimeActivation()
            }
            return
        }
        let wasVisible = wasOperationallyVisible
        wasOperationallyVisible = isVisible
        idleRefreshTask?.cancel()
        if wasVisible {
            recordLastViewed(for: selectedChannel)
        }
        if isVisible {
            requestScrollRuntimeActivation()
            scheduleIdleRefreshIfNeeded(for: selectedChannel)
        } else {
            dismissChannelIndicator(animated: false)
        }
    }

    private func requestScrollRuntimeActivation() {
        let nextRequest = scrollRuntimeActivationRequest &+ 1
        scrollRuntimeActivationRequest = nextRequest == 0 ? 1 : nextRequest
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
        case .recommendation:
            Task { await recommendationStore.recordLastViewed() }
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

}

private struct HomeFloatingSurface<Surface: InsettableShape, Content: View>: View {
    let surface: Surface
    let content: Content

    init(
        in surface: Surface,
        @ViewBuilder content: () -> Content
    ) {
        self.surface = surface
        self.content = content()
    }

    var body: some View {
        content
            .background(.ultraThinMaterial, in: surface)
            .overlay {
                surface.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    }
}

enum HomeFloatingControl: String, CaseIterable, Identifiable {
    case creation
    case notifications

    var id: String { rawValue }
    static let visibleControls: [HomeFloatingControl] = [.creation, .notifications]
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
