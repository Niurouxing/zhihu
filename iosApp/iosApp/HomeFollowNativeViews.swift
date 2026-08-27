import SwiftUI

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
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
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

private struct NativeHomeTopBarScrollTracking: ViewModifier {
    @Environment(\.nativeHomeTopBarScrollIntentAction) private var onIntent
    @State private var tracker = NativeHomeTopBarScrollIntentTracker()
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newOffset in
                if let intent = tracker.updateOffset(newOffset, isActive: isActive) {
                    onIntent(intent)
                }
            }
            .onScrollPhaseChange { _, newPhase, context in
                let offset = context.geometry.contentOffset.y
                    + context.geometry.contentInsets.top
                tracker.updateInteraction(
                    isInteracting: isActive && newPhase == .interacting,
                    offset: offset
                )
            }
            .onChange(of: isActive) { active in
                tracker.reset()
                if active { onIntent(.show) }
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
    case followingRecentUsers
    case following(FeedItemID)
    case followingStatus
    case hot(FeedItemID)
    case hotStatus
    case daily(Int64)
    case dailyStatus
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

enum NativeHomeListScrollAnchor: Hashable {
    case revealedTop(HomeChannel)
    case collapsedTop(HomeChannel)
}

struct NativeHomeRefreshRevealSpacer: View {
    let channel: HomeChannel
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
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .id(NativeHomeListScrollAnchor.revealedTop(channel))
        .accessibilityHidden(true)
    }
}

struct NativeHomePullSearchDrawer: View {
    let channel: HomeChannel
    let isRevealed: Bool
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
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .id(NativeHomeListScrollAnchor.collapsedTop(channel))
        // The persistent channel control exposes the same action while this row is covered.
        .accessibilityHidden(!isRevealed)
    }
}

struct NativeHomeMinimumScrollExtent: View {
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(height: max(height, NativeHomeMinimumScrollRangePolicy.minimumExtentHeight))
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityHidden(true)
    }
}

struct NativeHomeMinimumScrollRangePolicy {
    static let minimumExtentHeight: CGFloat = 1
    static let tolerance: CGFloat = 0.5

    static func extentHeight(
        currentExtentHeight: CGFloat,
        maximumNormalizedOffset: CGFloat,
        requiredMaximumOffset: CGFloat
    ) -> CGFloat {
        max(
            minimumExtentHeight,
            currentExtentHeight
                + requiredMaximumOffset
                - maximumNormalizedOffset
        )
    }
}

struct NativeHomeSearchDrawerVisibilityPolicy {
    static func isRevealed(
        normalizedOffset: CGFloat,
        drawerHeight: CGFloat = NativeHomeTopChromeLayout.searchDrawerHeight
    ) -> Bool {
        guard normalizedOffset.isFinite else { return false }
        return normalizedOffset
            < drawerHeight - NativeHomeSearchDrawerSnapPolicy.settledTolerance
    }
}

enum NativeHomeSearchDrawerSnapTarget: Equatable {
    case revealed
    case collapsed
}

enum NativeHomeSearchDrawerSettleReason: Equatable {
    case interactionEnded
    case layoutChanged
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

struct NativeHomeSearchDrawerSettlementDecision: Equatable {
    let settledTarget: NativeHomeSearchDrawerSnapTarget
    let scrollTarget: NativeHomeSearchDrawerSnapTarget?
}

struct NativeHomeSearchDrawerSettlementPolicy {
    static func decision(
        previousTarget: NativeHomeSearchDrawerSnapTarget,
        normalizedOffset: CGFloat,
        reason: NativeHomeSearchDrawerSettleReason,
        isRefreshing: Bool
    ) -> NativeHomeSearchDrawerSettlementDecision {
        guard normalizedOffset.isFinite, !isRefreshing else {
            return NativeHomeSearchDrawerSettlementDecision(
                settledTarget: previousTarget,
                scrollTarget: nil
            )
        }

        switch reason {
        case .interactionEnded:
            if normalizedOffset
                < -NativeHomeSearchDrawerSnapPolicy.settledTolerance {
                // Let the native bounce/refresh control finish before enforcing position.
                return NativeHomeSearchDrawerSettlementDecision(
                    settledTarget: .revealed,
                    scrollTarget: nil
                )
            }
            if let target = NativeHomeSearchDrawerSnapPolicy.target(
                normalizedOffset: normalizedOffset,
                isRefreshing: false
            ) {
                return NativeHomeSearchDrawerSettlementDecision(
                    settledTarget: target,
                    scrollTarget: target
                )
            }
            if normalizedOffset
                > NativeHomeTopChromeLayout.searchDrawerHeight
                    + NativeHomeSearchDrawerSnapPolicy.settledTolerance {
                return NativeHomeSearchDrawerSettlementDecision(
                    settledTarget: .collapsed,
                    scrollTarget: nil
                )
            }

        case .layoutChanged:
            let tolerance = NativeHomeSearchDrawerSnapPolicy.settledTolerance
            if normalizedOffset >= -tolerance,
               normalizedOffset
                <= NativeHomeTopChromeLayout.searchDrawerHeight + tolerance {
                return NativeHomeSearchDrawerSettlementDecision(
                    settledTarget: previousTarget,
                    scrollTarget: previousTarget
                )
            }
        }

        return NativeHomeSearchDrawerSettlementDecision(
            settledTarget: previousTarget,
            scrollTarget: nil
        )
    }
}

struct NativeHomeInitialTopAlignmentPolicy {
    static let maximumAttempts = 4
    static let validationDelay: TimeInterval = 0.12

    static func isAligned(
        normalizedOffset: CGFloat,
        targetOffset: CGFloat = NativeHomeTopChromeLayout.collapsedOffset
    ) -> Bool {
        normalizedOffset.isFinite
            && abs(normalizedOffset - targetOffset)
                <= NativeHomeSearchDrawerSnapPolicy.settledTolerance
    }

    static func canAttempt(after attempts: Int) -> Bool {
        attempts < maximumAttempts
    }
}

private struct NativeHomeTwoStagePullGeometry: ViewModifier {
    @Binding var extentHeight: CGFloat?
    @Binding var latestNormalizedOffset: CGFloat
    let initialExtentHeight: CGFloat
    let isActive: Bool
    let isRefreshing: Bool
    let isReady: Bool
    let onSettled: (CGFloat, NativeHomeSearchDrawerSettleReason) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(NativeHomeTwoStagePullGeometryAvailable(
                extentHeight: $extentHeight,
                latestNormalizedOffset: $latestNormalizedOffset,
                initialExtentHeight: initialExtentHeight,
                isActive: isActive,
                isRefreshing: isRefreshing,
                isReady: isReady,
                onSettled: onSettled
            ))
        } else {
            content
        }
    }
}

private struct NativeHomeScrollGeometryMetrics: Equatable {
    let normalizedOffset: CGFloat
    let maximumNormalizedOffset: CGFloat
}

@available(iOS 18.0, *)
private struct NativeHomeTwoStagePullGeometryAvailable: ViewModifier {
    @Binding var extentHeight: CGFloat?
    @Binding var latestNormalizedOffset: CGFloat
    let initialExtentHeight: CGFloat
    let isActive: Bool
    let isRefreshing: Bool
    let isReady: Bool
    let onSettled: (CGFloat, NativeHomeSearchDrawerSettleReason) -> Void
    @State private var isIdle = true
    @State private var didInteractSinceLastIdle = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: NativeHomeScrollGeometryMetrics.self) { geometry in
                NativeHomeScrollGeometryMetrics(
                    normalizedOffset: geometry.contentOffset.y + geometry.contentInsets.top,
                    maximumNormalizedOffset: geometry.contentSize.height
                        - geometry.containerSize.height
                        + geometry.contentInsets.top
                        + geometry.contentInsets.bottom
                )
            } action: { _, metrics in
                latestNormalizedOffset = metrics.normalizedOffset
                let didChangeExtent = updateExtentIfNeeded(using: metrics)
                if isReady, isActive, !isRefreshing, !didChangeExtent, isIdle {
                    onSettled(metrics.normalizedOffset, .layoutChanged)
                }
            }
            .onScrollPhaseChange { _, newPhase, context in
                if newPhase == .interacting {
                    didInteractSinceLastIdle = true
                }
                isIdle = newPhase == .idle
                let geometry = context.geometry
                let metrics = NativeHomeScrollGeometryMetrics(
                    normalizedOffset: geometry.contentOffset.y + geometry.contentInsets.top,
                    maximumNormalizedOffset: geometry.contentSize.height
                        - geometry.containerSize.height
                        + geometry.contentInsets.top
                        + geometry.contentInsets.bottom
                )
                latestNormalizedOffset = metrics.normalizedOffset
                guard isIdle else { return }
                let reason: NativeHomeSearchDrawerSettleReason = didInteractSinceLastIdle
                    ? .interactionEnded
                    : .layoutChanged
                didInteractSinceLastIdle = false
                let didChangeExtent = updateExtentIfNeeded(using: metrics)
                if isReady, isActive, !isRefreshing, !didChangeExtent {
                    onSettled(metrics.normalizedOffset, reason)
                }
            }
            .onChange(of: isActive) { active in
                if active, isReady, isIdle, !isRefreshing {
                    onSettled(latestNormalizedOffset, .layoutChanged)
                }
            }
    }

    @discardableResult
    private func updateExtentIfNeeded(using metrics: NativeHomeScrollGeometryMetrics) -> Bool {
        guard isIdle, !isRefreshing else { return false }
        let currentHeight = extentHeight ?? initialExtentHeight
        let desiredHeight = NativeHomeMinimumScrollRangePolicy.extentHeight(
            currentExtentHeight: currentHeight,
            maximumNormalizedOffset: metrics.maximumNormalizedOffset,
            requiredMaximumOffset: NativeHomeTopChromeLayout.searchDrawerHeight
        )
        if extentHeight != nil,
           abs(desiredHeight - currentHeight)
            <= NativeHomeMinimumScrollRangePolicy.tolerance {
            return false
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            extentHeight = desiredHeight
        }
        return true
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
    func nativeHomeTopBarScrollTracking(isActive: Bool) -> some View {
        modifier(NativeHomeTopBarScrollTracking(isActive: isActive))
    }

    func nativeHomeTwoStagePullGeometry(
        extentHeight: Binding<CGFloat?>,
        latestNormalizedOffset: Binding<CGFloat>,
        initialExtentHeight: CGFloat,
        isActive: Bool,
        isRefreshing: Bool,
        isReady: Bool,
        onSettled: @escaping (CGFloat, NativeHomeSearchDrawerSettleReason) -> Void
    ) -> some View {
        modifier(NativeHomeTwoStagePullGeometry(
            extentHeight: extentHeight,
            latestNormalizedOffset: latestNormalizedOffset,
            initialExtentHeight: initialExtentHeight,
            isActive: isActive,
            isRefreshing: isRefreshing,
            isReady: isReady,
            onSettled: onSettled
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
    @State private var hasAlignedInitialTop = false
    @State private var isInitialTopAlignmentScheduled = false
    @State private var initialTopAlignmentAttempts = 0
    @State private var isPullRefreshInFlight = false
    @State private var settledSearchDrawerTarget: NativeHomeSearchDrawerSnapTarget = .collapsed
    @State private var scrollExtentHeight: CGFloat?
    @State private var latestNormalizedOffset = CGFloat.nan
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
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                NativeHomeFeedScrollView {
                if let onOpenSearch {
                    NativeHomeRefreshRevealSpacer(
                        channel: .recommendation,
                        isRefreshing: isRefreshInFlight
                    )
                    NativeHomePullSearchDrawer(
                        channel: .recommendation,
                        isRevealed: NativeHomeSearchDrawerVisibilityPolicy.isRevealed(
                            normalizedOffset: latestNormalizedOffset
                        ),
                        action: onOpenSearch
                    )
                    .opacity(hasAlignedInitialTop ? 1 : 0)
                }

                if visibleItems.isEmpty {
                    recommendationEmptyState
                }

                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    let prefetchTaskID = NativeFeedPaginationPrefetchTaskIdentity(
                        isActive: isActiveChannel,
                        nextPage: store.nextPageLoadID,
                        isNearEnd: NativeFeedPaginationPrefetchPolicy.isNearEnd(
                            itemIndex: index,
                            itemCount: visibleItems.count
                        )
                    )
                    FeedItemRow(item: item, showsThumbnail: true) { route in
                        store.opened(item)
                        onOpen(route)
                    }
                    .id(NativeHomeContentScrollTarget.recommendation(item.id))
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

                if !visibleItems.isEmpty, let message = store.errorMessage {
                    FeedRetryRow(message: message) { Task { await store.retry() } }
                        .nativeFeedCardItemLayout()
                } else if !visibleItems.isEmpty, store.isLoading {
                    NativeFeedPaginationLoadingRow(title: "正在加载更多推荐")
                        .listRowSeparator(.hidden)
                }

                if store.hasNextPage {
                    let taskID = NativeChannelTaskIdentity(
                        isActive: isActiveChannel,
                        value: store.nextPageLoadID
                    )
                    Color.clear
                        .frame(height: 1)
                        .accessibilityHidden(true)
                        .task(id: taskID) {
                            guard taskID.isActive,
                                  taskID.value == store.nextPageLoadID
                            else { return }
                            await store.loadMore()
                        }
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
                    let outcome = await store.refresh(intent: .pull)
                    if outcome == .ignored {
                        hapticFeedback(.refreshIgnored)
                    }
                }
                .allowsHitTesting(hasAlignedInitialTop)
                .onAppear {
                    // A request token records an action that already happened. Returning
                    // from a pushed answer must not replay it and destroy List's retained
                    // scroll position. New requests are handled by onChange below.
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
        }
        .accessibilityIdentifier("home_native")
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
            anchor = .revealedTop(.recommendation)
        case .collapsed:
            anchor = .collapsedTop(.recommendation)
        }
        guard abs(normalizedOffset - targetOffset(for: target))
            > NativeHomeSearchDrawerSnapPolicy.settledTolerance
        else { return }
        scrollSearchDrawer(to: anchor, reason: reason, proxy: proxy)
    }

    private func scrollSearchDrawer(
        to anchor: NativeHomeListScrollAnchor,
        reason: NativeHomeSearchDrawerSettleReason,
        proxy: ScrollViewProxy
    ) {
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

    private func targetOffset(for target: NativeHomeSearchDrawerSnapTarget) -> CGFloat {
        switch target {
        case .revealed: return 0
        case .collapsed: return NativeHomeTopChromeLayout.searchDrawerHeight
        }
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
                .listRowSeparator(.hidden)
        } else if let message = store.errorMessage {
            FeedRetryRow(message: message) { Task { await store.retry() } }
                .nativeFeedCardItemLayout()
        } else if !store.hasNextPage {
            Label("暂无推荐", systemImage: "sparkles")
                .foregroundStyle(.secondary)
        }
    }

    private var isRefreshInFlight: Bool {
        isPullRefreshInFlight || store.isRefreshing
    }

    private var pullDrawerAnchor: NativeHomeListScrollAnchor {
        .collapsedTop(.recommendation)
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
            // Never keep programmatic scrolling alive long enough to compete with a user gesture.
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

struct FollowNativeView: View {
    @ObservedObject private var store: FollowNativeStore
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
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                NativeHomeFeedScrollView {
                if let onOpenSearch {
                    NativeHomeRefreshRevealSpacer(
                        channel: .following,
                        isRefreshing: isRefreshInFlight
                    )
                    NativeHomePullSearchDrawer(
                        channel: .following,
                        isRevealed: NativeHomeSearchDrawerVisibilityPolicy.isRevealed(
                            normalizedOffset: latestNormalizedOffset
                        ),
                        action: onOpenSearch
                    )
                    .opacity(hasAlignedInitialTop ? 1 : 0)
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
                        .nativeFeedCardItemLayout()
                }

                if let message = store.moments.errorMessage {
                    FeedRetryRow(message: message) {
                        Task { await store.retry(section: .moments) }
                    }
                    .id(NativeHomeContentScrollTarget.followingStatus)
                    .nativeFeedCardItemLayout()
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
                    await store.refresh(section: .moments)
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
            anchor = .revealedTop(.following)
        case .collapsed:
            anchor = .collapsedTop(.following)
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
            from: store.moments.items,
            blockedMemberIDs: questionAuthorBlocklist.blockedMemberIDs
        )
    }

    private var pullDrawerAnchor: NativeHomeListScrollAnchor {
        .collapsedTop(.following)
    }

    private var isRefreshInFlight: Bool {
        isPullRefreshInFlight || store.isMomentsRefreshing
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
                    .nativeFeedCardItemLayout()
            }
            .id(NativeHomeContentScrollTarget.followingRecentUsers)
        }
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
