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
    let triggerSequence: UInt
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

enum NativeHomeFloatingControlsScrollIntent: Equatable {
    case show
    case hide
}

struct NativeHomeFloatingControlsScrollEvent: Equatable {
    let channel: HomeChannel
    let intent: NativeHomeFloatingControlsScrollIntent
}

struct NativeHomeFloatingControlsScrollIntentTracker {
    static let hideDistance: CGFloat = 18
    static let minimumOffsetToHide = NativeHomePullRegionLayout.collapsedOffset
    /// Requires a small but deliberate reverse scroll before restoring chrome.
    /// Eight points filters finger jitter while remaining noticeably quicker than
    /// the longer distance used to hide the controls.
    static let showDistance: CGFloat = 8
    static let noiseTolerance: CGFloat = 0.5
    static let topTolerance: CGFloat = 1
    static let minimumSettlingVelocity: CGFloat = 80

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
    ) -> NativeHomeFloatingControlsScrollIntent? {
        guard offset.isFinite else {
            reset()
            return nil
        }

        guard isActive else {
            reset(offset: offset)
            return nil
        }

        if offset <= Self.minimumOffsetToHide + Self.topTolerance {
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

    /// Resolves a short flick that may not have crossed a distance threshold
    /// before the pan recognizer ended. UIKit continues that motion through
    /// deceleration, but the semantic controls state should be decided once at
    /// gesture completion instead of depending on later per-pixel callbacks.
    mutating func endInteraction(
        offset: CGFloat,
        verticalPanVelocity: CGFloat
    ) -> NativeHomeFloatingControlsScrollIntent? {
        defer { reset(offset: offset) }
        guard offset.isFinite, verticalPanVelocity.isFinite else { return nil }
        if offset <= Self.minimumOffsetToHide + Self.topTolerance { return .show }
        guard isInteracting,
              abs(verticalPanVelocity) >= Self.minimumSettlingVelocity
        else { return nil }
        if verticalPanVelocity > 0 { return .show }
        return offset >= Self.minimumOffsetToHide ? .hide : nil
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

/// Reduces SwiftUI's scroll geometry/phase callbacks to the two semantic
/// states understood by the root chrome. It deliberately owns no SwiftUI
/// state, so continuous scrolling does not invalidate the view hierarchy.
private final class NativeHomeFloatingControlsScrollDriver {
    private var tracker = NativeHomeFloatingControlsScrollIntentTracker()
    private var phase: ScrollPhase = .idle
    private var latestOffset: CGFloat?
    private var isActive = false
    private var needsSettledSynchronization = false

    func updateOffset(
        _ offset: CGFloat,
        isActive: Bool,
        emit: (NativeHomeFloatingControlsScrollIntent) -> Void
    ) {
        guard offset.isFinite else {
            latestOffset = nil
            tracker.reset()
            needsSettledSynchronization = isActive
            return
        }
        latestOffset = offset
        updateActivation(isActive, emit: emit)
        guard self.isActive else { return }

        if needsSettledSynchronization {
            needsSettledSynchronization = false
            tracker.reset(offset: offset)
            emit(settledIntent(for: offset))
            return
        }

        if isUserDriven(phase) {
            if let intent = tracker.updateOffset(offset, isActive: true) {
                emit(intent)
            }
        } else {
            tracker.reset(offset: offset)
            if offset <= NativeHomeFloatingControlsScrollIntentTracker.minimumOffsetToHide
                + NativeHomeFloatingControlsScrollIntentTracker.topTolerance {
                emit(.show)
            }
        }
    }

    func updatePhase(
        _ newPhase: ScrollPhase,
        normalizedOffset: CGFloat,
        isActive: Bool,
        emit: (NativeHomeFloatingControlsScrollIntent) -> Void
    ) {
        guard normalizedOffset.isFinite else { return }
        latestOffset = normalizedOffset
        updateActivation(isActive, emit: emit)

        let wasUserDriven = isUserDriven(phase)
        let isNowUserDriven = isUserDriven(newPhase)
        phase = newPhase
        guard self.isActive else {
            tracker.reset(offset: normalizedOffset)
            return
        }

        if needsSettledSynchronization {
            needsSettledSynchronization = false
            tracker.reset(offset: normalizedOffset)
            emit(settledIntent(for: normalizedOffset))
        }

        if !wasUserDriven, isNowUserDriven {
            tracker.updateInteraction(isInteracting: true, offset: normalizedOffset)
        } else if wasUserDriven, !isNowUserDriven {
            if let intent = tracker.updateOffset(normalizedOffset, isActive: true) {
                emit(intent)
            }
            if let intent = tracker.endInteraction(
                offset: normalizedOffset,
                verticalPanVelocity: 0
            ) {
                emit(intent)
            }
        }
    }

    func updateActivation(
        _ isActive: Bool,
        emit: (NativeHomeFloatingControlsScrollIntent) -> Void
    ) {
        guard self.isActive != isActive else { return }
        self.isActive = isActive
        tracker.reset(offset: latestOffset)
        guard isActive else {
            needsSettledSynchronization = false
            return
        }
        guard let latestOffset else {
            needsSettledSynchronization = true
            return
        }
        needsSettledSynchronization = false
        emit(settledIntent(for: latestOffset))
    }

    func synchronize(
        isActive: Bool,
        emit: (NativeHomeFloatingControlsScrollIntent) -> Void
    ) {
        updateActivation(isActive, emit: emit)
        guard self.isActive else { return }
        guard let latestOffset else {
            needsSettledSynchronization = true
            return
        }
        needsSettledSynchronization = false
        tracker.reset(offset: latestOffset)
        emit(settledIntent(for: latestOffset))
    }

    private func settledIntent(
        for offset: CGFloat
    ) -> NativeHomeFloatingControlsScrollIntent {
        offset <= NativeHomeFloatingControlsScrollIntentTracker.minimumOffsetToHide
            + NativeHomeFloatingControlsScrollIntentTracker.topTolerance
            ? .show
            : .hide
    }

    private func isUserDriven(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating:
            return true
        case .idle, .animating:
            return false
        }
    }
}

private enum NativeHomeScrollGeometryPolicy {
    static let quantizationScale: CGFloat = 2

    static func normalizedOffset(_ geometry: ScrollGeometry) -> CGFloat {
        let rawOffset = geometry.contentOffset.y + geometry.contentInsets.top
        return (rawOffset * quantizationScale).rounded() / quantizationScale
    }
}

private struct NativeHomeFloatingControlsScrollIntentActionKey: EnvironmentKey {
    static let defaultValue: (NativeHomeFloatingControlsScrollEvent) -> Void = { _ in }
}

private struct NativeHomeScrollRuntimeActivationRequestKey: EnvironmentKey {
    static let defaultValue: UInt = 0
}

extension EnvironmentValues {
    var nativeHomeFloatingControlsScrollIntentAction:
        (NativeHomeFloatingControlsScrollEvent) -> Void {
        get { self[NativeHomeFloatingControlsScrollIntentActionKey.self] }
        set { self[NativeHomeFloatingControlsScrollIntentActionKey.self] = newValue }
    }

    var nativeHomeScrollRuntimeActivationRequest: UInt {
        get { self[NativeHomeScrollRuntimeActivationRequestKey.self] }
        set { self[NativeHomeScrollRuntimeActivationRequestKey.self] = newValue }
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
        offsets[channel] = max(offset, NativeHomePullRegionLayout.revealedOffset)
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

enum NativeHomeFloatingControlsLayout {
    static let height: CGFloat = 56
    static let controlHeight: CGFloat = 44
    static let contentClearance = height
    static let horizontalInset: CGFloat = 12
}

/// Defines the natural scroll-space sequence before the first feed card:
/// clearance for the floating controls, followed by the search drawer.
/// At the normal feed position the clearance is scrolled out and the hidden drawer
/// occupies the controls' overlay lane. Revealing the drawer moves it immediately
/// below the controls, with the first card following directly after it.
enum NativeHomePullRegionLayout {
    static let searchDrawerHeight: CGFloat = 56
    static let revealedOffset: CGFloat = 0
    static let collapsedOffset = NativeHomeFloatingControlsLayout.contentClearance
    static let leadingContentHeight = NativeHomeFloatingControlsLayout.contentClearance
        + searchDrawerHeight
    static let searchFieldHeight: CGFloat = 36
    static let searchBottomInset: CGFloat = 6
}

struct NativeHomePullSearchDrawer: View {
    let isPresented: Bool
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
                    minHeight: NativeHomePullRegionLayout.searchFieldHeight,
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
            .padding(.bottom, NativeHomePullRegionLayout.searchBottomInset)
        }
        .frame(height: NativeHomePullRegionLayout.searchDrawerHeight)
        .opacity(isPresented ? 1 : 0)
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
    }
}

enum NativeHomeSearchDrawerAnchor: Equatable {
    case revealed
    case collapsed

    var normalizedOffset: CGFloat {
        switch self {
        case .revealed: NativeHomePullRegionLayout.revealedOffset
        case .collapsed: NativeHomePullRegionLayout.collapsedOffset
        }
    }
}

struct NativeHomeSearchDrawerSnapPolicy {
    static let revealDistance: CGFloat = 18
    static let collapseDistance: CGFloat = 4
    static let settledTolerance: CGFloat = 0.75

    static func boundaryAnchor(
        normalizedOffset: CGFloat
    ) -> NativeHomeSearchDrawerAnchor? {
        guard normalizedOffset.isFinite else { return nil }
        if normalizedOffset
            <= NativeHomePullRegionLayout.revealedOffset + settledTolerance {
            return .revealed
        }
        if normalizedOffset
            > NativeHomePullRegionLayout.collapsedOffset + settledTolerance {
            return .collapsed
        }
        return nil
    }

    static func target(
        normalizedOffset: CGFloat,
        currentAnchor: NativeHomeSearchDrawerAnchor,
        revealedOffset: CGFloat = NativeHomePullRegionLayout.revealedOffset,
        collapsedOffset: CGFloat = NativeHomePullRegionLayout.collapsedOffset,
        isRefreshing: Bool
    ) -> NativeHomeSearchDrawerAnchor? {
        guard normalizedOffset.isFinite, !isRefreshing else { return nil }
        guard normalizedOffset >= revealedOffset - settledTolerance,
              normalizedOffset <= collapsedOffset + settledTolerance
        else { return nil }
        if normalizedOffset <= revealedOffset + settledTolerance { return .revealed }
        if normalizedOffset >= collapsedOffset - settledTolerance { return .collapsed }

        switch currentAnchor {
        case .collapsed:
            return collapsedOffset - normalizedOffset >= revealDistance
                ? .revealed
                : .collapsed
        case .revealed:
            return normalizedOffset - revealedOffset >= collapseDistance
                ? .collapsed
                : .revealed
        }
    }
}

struct NativeHomeSearchDrawerRestoredPosition: Equatable {
    let normalizedOffset: CGFloat
    let anchor: NativeHomeSearchDrawerAnchor
}

struct NativeHomeSearchDrawerRestorationPolicy {
    static func resolve(
        restoredNormalizedOffset: CGFloat?,
        maximumNormalizedOffset: CGFloat
    ) -> NativeHomeSearchDrawerRestoredPosition {
        let revealedOffset = NativeHomePullRegionLayout.revealedOffset
        let collapsedOffset = NativeHomePullRegionLayout.collapsedOffset
        let restoredOffset = restoredNormalizedOffset.flatMap { $0.isFinite ? $0 : nil }
            ?? collapsedOffset
        let clampedOffset = min(
            max(restoredOffset, revealedOffset),
            maximumNormalizedOffset
        )

        guard clampedOffset < collapsedOffset else {
            return NativeHomeSearchDrawerRestoredPosition(
                normalizedOffset: clampedOffset,
                anchor: .collapsed
            )
        }

        let midpoint = revealedOffset + (collapsedOffset - revealedOffset) / 2
        let anchor: NativeHomeSearchDrawerAnchor = clampedOffset <= midpoint
            ? .revealed
            : .collapsed
        return NativeHomeSearchDrawerRestoredPosition(
            normalizedOffset: anchor.normalizedOffset,
            anchor: anchor
        )
    }
}

/// Measures the user's finger travel rather than rubber-banded content offset.
/// That keeps the second pull stage short and predictable after the search
/// drawer has been exposed.
enum NativeHomeRefreshTriggerPolicy {
    static let pullDistanceBeyondSearch: CGFloat = 10
    static let topStartTolerance: CGFloat = 2

    static func shouldRequestRefresh(
        interactionStartOffset: CGFloat,
        maximumDownwardTranslation: CGFloat,
        hasSearchDrawer: Bool,
        isActive: Bool,
        isRefreshInFlight: Bool
    ) -> Bool {
        guard interactionStartOffset.isFinite,
              maximumDownwardTranslation.isFinite,
              isActive,
              !isRefreshInFlight
        else { return false }
        let maximumStartOffset = hasSearchDrawer
            ? NativeHomePullRegionLayout.collapsedOffset + topStartTolerance
            : topStartTolerance
        guard interactionStartOffset <= maximumStartOffset else { return false }

        let distanceToReveal = hasSearchDrawer
            ? max(
                0,
                interactionStartOffset - NativeHomePullRegionLayout.revealedOffset
            )
            : max(0, interactionStartOffset)
        return maximumDownwardTranslation
            >= distanceToReveal + pullDistanceBeyondSearch
    }
}

private struct NativeHomeScrollRuntimeConfiguration: Equatable {
    let isActive: Bool
    let activationRequest: UInt
    let scrollToTopRequest: UInt
    let hasSearchDrawer: Bool
    let isRefreshInFlight: Bool
    let restoredNormalizedOffset: CGFloat?
}

/// Owns the native scroll interaction without publishing per-pixel offsets into SwiftUI.
/// Search reveal is represented by a two-anchor state machine over the scroll
/// view's natural `revealedOffset...collapsedOffset` range. SwiftUI receives
/// only semantic anchor changes. SwiftUI owns the one visible refresh indicator,
/// while this runtime owns gesture recognition and stable scroll positioning.
private struct NativeHomeScrollRuntimeBridge: UIViewRepresentable {
    let configuration: NativeHomeScrollRuntimeConfiguration
    let onRefreshRequested: (@escaping () -> Void) -> Void
    let onPrepared: (NativeHomeSearchDrawerAnchor) -> Void
    let onSearchDrawerAnchorChanged: (NativeHomeSearchDrawerAnchor) -> Void
    let onOffsetSaved: (CGFloat) -> Void

    func makeUIView(context: Context) -> NativeHomeScrollRuntimeView {
        let view = NativeHomeScrollRuntimeView()
        view.configure(
            configuration: configuration,
            onRefreshRequested: onRefreshRequested,
            onPrepared: onPrepared,
            onSearchDrawerAnchorChanged: onSearchDrawerAnchorChanged,
            onOffsetSaved: onOffsetSaved
        )
        return view
    }

    func updateUIView(_ uiView: NativeHomeScrollRuntimeView, context: Context) {
        uiView.configure(
            configuration: configuration,
            onRefreshRequested: onRefreshRequested,
            onPrepared: onPrepared,
            onSearchDrawerAnchorChanged: onSearchDrawerAnchorChanged,
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
        activationRequest: 0,
        scrollToTopRequest: 0,
        hasSearchDrawer: false,
        isRefreshInFlight: false,
        restoredNormalizedOffset: nil
    )
    private var onRefreshRequested: (@escaping () -> Void) -> Void = { completion in
        completion()
    }
    private var onPrepared: (NativeHomeSearchDrawerAnchor) -> Void = { _ in }
    private var onSearchDrawerAnchorChanged: (NativeHomeSearchDrawerAnchor) -> Void = { _ in }
    private var onOffsetSaved: (CGFloat) -> Void = { _ in }
    private var searchDrawerAnchor: NativeHomeSearchDrawerAnchor = .collapsed
    private var lastHandledScrollRequest: UInt?
    private var didPrepareInitialPosition = false
    private var isInstallationScheduled = false
    private var isActiveRebindingScheduled = false
    private var isProgrammaticScrollScheduled = false
    private var isRefreshRequestPending = false
    private var didRequestRefreshDuringCurrentInteraction = false
    private var refreshRequestGeneration: UInt = 0
    private var refreshInteractionStartOffset: CGFloat?
    private var maximumRefreshPullTranslation: CGFloat = 0
    private var pendingRestoredNormalizedOffset: CGFloat?

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
        if let scrollView, isDescendant(of: scrollView) {
            prepareInitialPositionIfPossible()
        } else {
            scheduleInstallation()
        }
    }

    func configure(
        configuration: NativeHomeScrollRuntimeConfiguration,
        onRefreshRequested: @escaping (@escaping () -> Void) -> Void,
        onPrepared: @escaping (NativeHomeSearchDrawerAnchor) -> Void,
        onSearchDrawerAnchorChanged: @escaping (NativeHomeSearchDrawerAnchor) -> Void,
        onOffsetSaved: @escaping (CGFloat) -> Void
    ) {
        let wasActive = self.configuration.isActive
        let activationRequestChanged = self.configuration.activationRequest
            != configuration.activationRequest
        self.configuration = configuration
        self.onRefreshRequested = onRefreshRequested
        self.onPrepared = onPrepared
        self.onSearchDrawerAnchorChanged = onSearchDrawerAnchorChanged
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
        } else if configuration.isActive,
                  !wasActive || activationRequestChanged {
            scheduleActiveRuntimeRebinding()
        }

        scheduleInstallation()
    }

    func uninstall() {
        saveCurrentOffset()
        detach(from: scrollView)
        scrollView = nil
        isInstallationScheduled = false
        isActiveRebindingScheduled = false
        isProgrammaticScrollScheduled = false
        isRefreshRequestPending = false
        didRequestRefreshDuringCurrentInteraction = false
        refreshInteractionStartOffset = nil
        maximumRefreshPullTranslation = 0
        pendingRestoredNormalizedOffset = nil
        refreshRequestGeneration &+= 1
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

    private func installIfNeeded(forceGestureRebind: Bool = false) {
        guard window != nil, let candidate = enclosingScrollView() else { return }
        if scrollView !== candidate {
            if didPrepareInitialPosition, let previousScrollView = scrollView {
                let carriedOffset = normalizedOffset(in: previousScrollView)
                pendingRestoredNormalizedOffset = carriedOffset
                onOffsetSaved(carriedOffset)
            }
            detach(from: scrollView)
            scrollView = candidate
            didPrepareInitialPosition = false
            candidate.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        } else if forceGestureRebind {
            detach(from: candidate)
            candidate.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        }
        candidate.layoutIfNeeded()
        prepareInitialPositionIfPossible()
    }

    private func detach(from scrollView: UIScrollView?) {
        scrollView?.panGestureRecognizer.removeTarget(
            self,
            action: #selector(handlePan(_:))
        )
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
            let minimumOffset = NativeHomePullRegionLayout.collapsedOffset
            let maximumOffset = maximumNormalizedOffset(in: scrollView)
            guard maximumOffset
                    >= minimumOffset - NativeHomeSearchDrawerSnapPolicy.settledTolerance
            else { return }
            let restoredPosition = NativeHomeSearchDrawerRestorationPolicy.resolve(
                restoredNormalizedOffset: pendingRestoredNormalizedOffset
                    ?? configuration.restoredNormalizedOffset,
                maximumNormalizedOffset: maximumOffset
            )
            searchDrawerAnchor = restoredPosition.anchor
            setNormalizedOffset(
                restoredPosition.normalizedOffset,
                in: scrollView,
                animated: false
            )
        }

        pendingRestoredNormalizedOffset = nil
        didPrepareInitialPosition = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onPrepared(self.searchDrawerAnchor)
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
            if self.configuration.hasSearchDrawer {
                self.transitionSearchDrawer(to: .collapsed)
            }
            self.setNormalizedOffset(
                self.configuration.hasSearchDrawer
                    ? NativeHomePullRegionLayout.collapsedOffset
                    : 0,
                in: scrollView,
                animated: animated
            )
            self.onOffsetSaved(
                self.configuration.hasSearchDrawer
                    ? NativeHomePullRegionLayout.collapsedOffset
                    : 0
            )
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let scrollView, configuration.isActive else { return }
        let offset = normalizedOffset(in: scrollView)
        switch recognizer.state {
        case .began:
            didRequestRefreshDuringCurrentInteraction = false
            refreshInteractionStartOffset = offset
            maximumRefreshPullTranslation = 0
        case .changed:
            maximumRefreshPullTranslation = max(
                maximumRefreshPullTranslation,
                recognizer.translation(in: scrollView).y
            )
            synchronizeSearchDrawerAtInteractiveBoundary(normalizedOffset: offset)
        case .ended:
            maximumRefreshPullTranslation = max(
                maximumRefreshPullTranslation,
                recognizer.translation(in: scrollView).y
            )
            if let refreshInteractionStartOffset,
               NativeHomeRefreshTriggerPolicy.shouldRequestRefresh(
                interactionStartOffset: refreshInteractionStartOffset,
                maximumDownwardTranslation: maximumRefreshPullTranslation,
                hasSearchDrawer: configuration.hasSearchDrawer,
                isActive: configuration.isActive,
                isRefreshInFlight: configuration.isRefreshInFlight
                    || isRefreshRequestPending
            ) {
                requestRefresh()
            }
            resetRefreshGestureTracking()
            if configuration.isRefreshInFlight || isRefreshRequestPending {
                transitionSearchDrawer(to: .revealed)
                holdRefreshPresentation(in: scrollView)
                onOffsetSaved(NativeHomePullRegionLayout.revealedOffset)
            } else if let settledOffset = settleSearchDrawer(
                in: scrollView,
                normalizedOffset: offset
            ) {
                onOffsetSaved(settledOffset)
            } else {
                saveCurrentOffset()
            }
        case .cancelled, .failed:
            resetRefreshGestureTracking()
            if configuration.isRefreshInFlight || isRefreshRequestPending {
                onOffsetSaved(NativeHomePullRegionLayout.revealedOffset)
            } else if let settledOffset = settleSearchDrawer(
                in: scrollView,
                normalizedOffset: offset
            ) {
                onOffsetSaved(settledOffset)
            } else {
                saveCurrentOffset()
            }
        default:
            break
        }
    }

    private func resetRefreshGestureTracking() {
        refreshInteractionStartOffset = nil
        maximumRefreshPullTranslation = 0
    }

    private func requestRefresh() {
        guard configuration.isActive,
              !configuration.isRefreshInFlight,
              !isRefreshRequestPending,
              !didRequestRefreshDuringCurrentInteraction
        else { return }
        isRefreshRequestPending = true
        didRequestRefreshDuringCurrentInteraction = true
        transitionSearchDrawer(to: .revealed)
        refreshRequestGeneration &+= 1
        let requestGeneration = refreshRequestGeneration
        onRefreshRequested { [weak self] in
            DispatchQueue.main.async {
                guard let self,
                      self.refreshRequestGeneration == requestGeneration
                else { return }
                self.finishRefreshPresentation()
            }
        }
    }

    private func holdRefreshPresentation(in scrollView: UIScrollView) {
        setNormalizedOffset(
            NativeHomePullRegionLayout.revealedOffset,
            in: scrollView,
            animated: true
        )
    }

    private func finishRefreshPresentation() {
        isRefreshRequestPending = false
        guard let scrollView else { return }
        let offset = normalizedOffset(in: scrollView)
        let isWithinTopRegion = offset
            <= NativeHomePullRegionLayout.collapsedOffset
                + NativeHomeSearchDrawerSnapPolicy.settledTolerance

        if isWithinTopRegion {
            if configuration.hasSearchDrawer {
                transitionSearchDrawer(to: .revealed)
            }
            onOffsetSaved(NativeHomePullRegionLayout.revealedOffset)
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self,
                      let scrollView,
                      !self.configuration.isRefreshInFlight,
                      !scrollView.isDragging,
                      self.normalizedOffset(in: scrollView)
                        < NativeHomePullRegionLayout.revealedOffset
                            - NativeHomeSearchDrawerSnapPolicy.settledTolerance
                else { return }
                self.setNormalizedOffset(
                    NativeHomePullRegionLayout.revealedOffset,
                    in: scrollView,
                    animated: true
                )
            }
        } else {
            if configuration.hasSearchDrawer {
                transitionSearchDrawer(to: .collapsed)
            }
            onOffsetSaved(offset)
        }
    }

    /// Reacquires the feed scroll view after navigation transitions. This bridge
    /// has no authority over floating-control visibility; it only restores the
    /// search/refresh gesture target if SwiftUI rebuilt the underlying scroll view.
    private func scheduleActiveRuntimeRebinding() {
        guard !isActiveRebindingScheduled else { return }
        isActiveRebindingScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isActiveRebindingScheduled = false
            guard self.configuration.isActive else { return }
            self.installIfNeeded(forceGestureRebind: true)
        }
    }

    private func settleSearchDrawer(
        in scrollView: UIScrollView,
        normalizedOffset: CGFloat
    ) -> CGFloat? {
        guard configuration.hasSearchDrawer else { return nil }

        if let boundaryAnchor = NativeHomeSearchDrawerSnapPolicy.boundaryAnchor(
            normalizedOffset: normalizedOffset
        ) {
            transitionSearchDrawer(to: boundaryAnchor)
        }

        if normalizedOffset
            > NativeHomePullRegionLayout.collapsedOffset
                + NativeHomeSearchDrawerSnapPolicy.settledTolerance {
            return nil
        }

        guard let target = NativeHomeSearchDrawerSnapPolicy.target(
            normalizedOffset: normalizedOffset,
            currentAnchor: searchDrawerAnchor,
            isRefreshing: configuration.isRefreshInFlight
                || isRefreshRequestPending
        )
        else { return nil }

        transitionSearchDrawer(to: target)
        let targetOffset = target.normalizedOffset
        if abs(normalizedOffset - targetOffset)
            > NativeHomeSearchDrawerSnapPolicy.settledTolerance {
            setNormalizedOffset(targetOffset, in: scrollView, animated: true)
        }
        return targetOffset
    }

    private func synchronizeSearchDrawerAtInteractiveBoundary(normalizedOffset: CGFloat) {
        guard configuration.hasSearchDrawer else { return }
        guard let boundaryAnchor = NativeHomeSearchDrawerSnapPolicy.boundaryAnchor(
            normalizedOffset: normalizedOffset
        ) else { return }
        transitionSearchDrawer(to: boundaryAnchor)
    }

    private func transitionSearchDrawer(to anchor: NativeHomeSearchDrawerAnchor) {
        guard anchor != searchDrawerAnchor else { return }
        searchDrawerAnchor = anchor
        onSearchDrawerAnchorChanged(anchor)
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
/// continuous chrome tracking is reduced without publishing per-frame state, while
/// the native bridge is limited to search/refresh positioning.
struct NativeHomeChannelScrollView<Content: View>: View {
    @Environment(\.nativeHomeFloatingControlsScrollIntentAction)
    private var onFloatingControlsIntent
    @Environment(\.nativeHomeScrollPositionRegistry) private var positionRegistry
    @Environment(\.nativeHomeScrollRuntimeActivationRequest)
    private var runtimeActivationRequest
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floatingControlsScrollDriver =
        NativeHomeFloatingControlsScrollDriver()
    @State private var isPrepared: Bool
    @State private var isPullRefreshInFlight = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var searchDrawerAnchor: NativeHomeSearchDrawerAnchor = .collapsed

    let channel: HomeChannel
    let isActive: Bool
    let scrollToTopRequest: UInt
    let onOpenSearch: (() -> Void)?
    let onRefresh: () async -> Void
    private let content: Content

    init(
        channel: HomeChannel,
        isActive: Bool,
        scrollToTopRequest: UInt,
        onOpenSearch: (() -> Void)?,
        onRefresh: @escaping () async -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.channel = channel
        self.isActive = isActive
        self.scrollToTopRequest = scrollToTopRequest
        self.onOpenSearch = onOpenSearch
        self.onRefresh = onRefresh
        self.content = content()
        _isPrepared = State(initialValue: onOpenSearch == nil)
    }

    var body: some View {
        GeometryReader { viewport in
            NativeHomeFeedScrollView(
                minimumContentHeight: viewport.size.height
                    + (onOpenSearch == nil ? 0 : NativeHomePullRegionLayout.leadingContentHeight)
            ) {
                NativeHomeScrollRuntimeBridge(
                    configuration: NativeHomeScrollRuntimeConfiguration(
                        isActive: isActive,
                        activationRequest: runtimeActivationRequest,
                        scrollToTopRequest: scrollToTopRequest,
                        hasSearchDrawer: onOpenSearch != nil,
                        isRefreshInFlight: isPullRefreshInFlight,
                        restoredNormalizedOffset: positionRegistry?.offset(for: channel)
                    ),
                    onRefreshRequested: requestRefresh,
                    onPrepared: markPrepared,
                    onSearchDrawerAnchorChanged: updateSearchDrawerAnchor,
                    onOffsetSaved: saveOffset
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

                if let onOpenSearch {
                    ZStack {
                        Color.clear
                        if isPullRefreshInFlight {
                            ProgressView()
                                .controlSize(.regular)
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    }
                    .frame(height: NativeHomeFloatingControlsLayout.contentClearance)
                    .accessibilityHidden(true)
                    NativeHomePullSearchDrawer(
                        isPresented: searchDrawerAnchor == .revealed,
                        action: onOpenSearch
                    )
                }

                content
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                NativeHomeScrollGeometryPolicy.normalizedOffset(geometry)
            } action: { _, normalizedOffset in
                floatingControlsScrollDriver.updateOffset(
                    normalizedOffset,
                    isActive: isActive,
                    emit: reportFloatingControlsIntent
                )
            }
            .onScrollPhaseChange { _, newPhase, context in
                floatingControlsScrollDriver.updatePhase(
                    newPhase,
                    normalizedOffset: NativeHomeScrollGeometryPolicy.normalizedOffset(
                        context.geometry
                    ),
                    isActive: isActive,
                    emit: reportFloatingControlsIntent
                )
            }
            .opacity(isPrepared ? 1 : 0)
            .allowsHitTesting(isPrepared)
        }
        .onAppear {
            floatingControlsScrollDriver.synchronize(
                isActive: isActive,
                emit: reportFloatingControlsIntent
            )
        }
        .onChange(of: isActive) { _, active in
            floatingControlsScrollDriver.updateActivation(
                active,
                emit: reportFloatingControlsIntent
            )
        }
        .onChange(of: runtimeActivationRequest) { _, _ in
            floatingControlsScrollDriver.synchronize(
                isActive: isActive,
                emit: reportFloatingControlsIntent
            )
        }
        .onDisappear {
            floatingControlsScrollDriver.updateActivation(
                false,
                emit: reportFloatingControlsIntent
            )
            refreshTask?.cancel()
            refreshTask = nil
            isPullRefreshInFlight = false
        }
    }

    private func reportFloatingControlsIntent(
        _ intent: NativeHomeFloatingControlsScrollIntent
    ) {
        onFloatingControlsIntent(.init(channel: channel, intent: intent))
    }

    private func markPrepared(anchor: NativeHomeSearchDrawerAnchor) {
        if searchDrawerAnchor != anchor {
            searchDrawerAnchor = anchor
        }
        if !isPrepared {
            isPrepared = true
        }
    }

    private func updateSearchDrawerAnchor(_ anchor: NativeHomeSearchDrawerAnchor) {
        guard anchor != searchDrawerAnchor else { return }
        if reduceMotion {
            searchDrawerAnchor = anchor
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                searchDrawerAnchor = anchor
            }
        }
    }

    private func saveOffset(_ offset: CGFloat) {
        positionRegistry?.save(offset, for: channel)
    }

    private func requestRefresh(completion: @escaping () -> Void) {
        guard isActive, !isPullRefreshInFlight else {
            completion()
            return
        }
        isPullRefreshInFlight = true
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            await onRefresh()
            let wasCancelled = Task.isCancelled
            if !wasCancelled {
                isPullRefreshInFlight = false
                refreshTask = nil
            }
            completion()
        }
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
                    ),
                    triggerSequence: store.paginationTriggerSequence
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
                          prefetchTaskID.nextPage == store.nextPageLoadID,
                          prefetchTaskID.triggerSequence
                            == store.paginationTriggerSequence
                    else { return }
                    await store.loadMore()
                }
            }

            if !items.isEmpty, let message = store.errorMessage {
                FeedRetryRow(message: message) { Task { await store.retry() } }
                    .nativeFeedCardItemLayout()
            } else if !items.isEmpty, store.isLoadingNextPage {
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
