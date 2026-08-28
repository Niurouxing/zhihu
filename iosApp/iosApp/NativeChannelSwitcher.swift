import SwiftUI
import UIKit

/// A top channel selector whose stable channel views move as one horizontal page strip.
struct NativeChannelSwitcher<Channel: Identifiable & Hashable, ChannelContent: View>: View {
    let channels: [Channel]
    @Binding var selection: Channel.ID
    let isEnabled: Bool

    private let content: (Channel) -> ChannelContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @State private var dragTranslation: CGFloat = 0

    init(
        channels: [Channel],
        selection: Binding<Channel.ID>,
        isEnabled: Bool = true,
        @ViewBuilder content: @escaping (Channel) -> ChannelContent
    ) {
        self.channels = channels
        _selection = selection
        self.isEnabled = isEnabled
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            channelContent(containerWidth: geometry.size.width)
                .contentShape(Rectangle())
                .background {
                    NativeHorizontalChannelSwipeObserver(
                        isEnabled: isEnabled,
                        containerWidth: geometry.size.width,
                        onChanged: updateChannelSwipe,
                        onCancelled: cancelChannelSwipe,
                        onEnded: commitChannelSwipe
                    )
                }
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            if shouldReduceMotion { dragTranslation = 0 }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { dragTranslation = 0 }
        }
        .onDisappear { dragTranslation = 0 }
    }

    private func channelContent(containerWidth: CGFloat) -> some View {
        ZStack {
            ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                if NativeChannelPresentationPolicy.shouldMount(
                    pageIndex: index,
                    selectedIndex: selectedChannelIndex,
                    channelCount: channels.count
                ) {
                    let isActive = NativeChannelPresentationPolicy.isActive(
                        isEnabled: isEnabled,
                        channelID: channel.id,
                        selection: selection
                    )
                    content(channel)
                        .frame(width: containerWidth)
                        .offset(x: NativeChannelPageTransitionPolicy.pageOffset(
                            pageIndex: index,
                            selectedIndex: selectedChannelIndex,
                            containerWidth: containerWidth,
                            dragTranslation: dragTranslation
                        ))
                        .zIndex(isActive ? 1 : 0)
                        .scrollDisabled(!isActive)
                        .allowsHitTesting(isActive && dragTranslation == 0)
                        .accessibilityHidden(!isActive)
                        .environment(\.nativeChannelIsActive, isActive)
                }
            }
        }
        .clipped()
    }

    private var selectedChannelIndex: Int {
        channels.firstIndex(where: { $0.id == selection }) ?? 0
    }

    private func updateChannelSwipe(_ translation: CGSize, _ containerWidth: CGFloat) {
        guard isEnabled else { return }
        dragTranslation = NativeChannelPageTransitionPolicy.interactiveTranslation(
            rawTranslation: translation.width,
            currentIndex: selectedChannelIndex,
            channelCount: channels.count,
            containerWidth: containerWidth
        )
    }

    private func cancelChannelSwipe() {
        if reduceMotion {
            dragTranslation = 0
        } else {
            withAnimation(NativeChannelSwitcherTuning.pageAnimation) {
                dragTranslation = 0
            }
        }
    }

    private func commitChannelSwipe(
        _ translation: CGSize,
        _ predictedEndTranslation: CGSize,
        _ containerWidth: CGFloat
    ) {
        guard isEnabled else {
            dragTranslation = 0
            return
        }
        guard let currentIndex = channels.firstIndex(where: { $0.id == selection }) else {
            return
        }

        let targetIndex = NativeChannelSwipePolicy.targetIndex(
            currentIndex: currentIndex,
            channelCount: channels.count,
            translation: translation,
            predictedEndTranslation: predictedEndTranslation,
            containerWidth: containerWidth
        )
        let targetSelection = channels[targetIndex].id
        if reduceMotion {
            dragTranslation = 0
            if targetIndex != currentIndex { selection = targetSelection }
        } else {
            withAnimation(NativeChannelSwitcherTuning.pageAnimation) {
                dragTranslation = 0
                if targetIndex != currentIndex { selection = targetSelection }
            }
        }
        if targetIndex != currentIndex { hapticFeedback(.commit) }
    }
}

struct NativeChannelPresentationPolicy {
    static func isActive<ID: Equatable>(
        isEnabled: Bool,
        channelID: ID,
        selection: ID
    ) -> Bool {
        isEnabled && channelID == selection
    }

    static func shouldMount(
        pageIndex: Int,
        selectedIndex: Int,
        channelCount: Int
    ) -> Bool {
        guard pageIndex >= 0,
              selectedIndex >= 0,
              pageIndex < channelCount,
              selectedIndex < channelCount
        else { return false }
        return abs(pageIndex - selectedIndex) <= 1
    }
}

struct NativeChannelPageTransitionPolicy {
    static func pageOffset(
        pageIndex: Int,
        selectedIndex: Int,
        containerWidth: CGFloat,
        dragTranslation: CGFloat
    ) -> CGFloat {
        CGFloat(pageIndex - selectedIndex) * containerWidth + dragTranslation
    }

    static func interactiveTranslation(
        rawTranslation: CGFloat,
        currentIndex: Int,
        channelCount: Int,
        containerWidth: CGFloat
    ) -> CGFloat {
        guard channelCount > 0,
              currentIndex >= 0,
              currentIndex < channelCount,
              containerWidth > 0
        else { return 0 }
        if currentIndex == 0, rawTranslation > 0 { return 0 }
        if currentIndex == channelCount - 1, rawTranslation < 0 { return 0 }
        return min(max(rawTranslation, -containerWidth), containerWidth)
    }
}

/// Installs a direction-locking pan recognizer on the surrounding SwiftUI host view.
///
/// A SwiftUI `DragGesture` enters recognition before its `onEnded` direction check, which
/// prevents the nested `List` from owning a vertical pull-to-refresh. This recognizer fails
/// before beginning unless the initial velocity is predominantly horizontal, leaving vertical
/// pans entirely to the native scroll view.
private struct NativeHorizontalChannelSwipeObserver: UIViewRepresentable {
    let isEnabled: Bool
    let containerWidth: CGFloat
    let onChanged: (CGSize, CGFloat) -> Void
    let onCancelled: () -> Void
    let onEnded: (CGSize, CGSize, CGFloat) -> Void

    func makeUIView(context: Context) -> NativeHorizontalChannelSwipeInstallerView {
        let view = NativeHorizontalChannelSwipeInstallerView()
        view.isUserInteractionEnabled = false
        update(view)
        return view
    }

    func updateUIView(
        _ uiView: NativeHorizontalChannelSwipeInstallerView,
        context: Context
    ) {
        update(uiView)
    }

    static func dismantleUIView(
        _ uiView: NativeHorizontalChannelSwipeInstallerView,
        coordinator: ()
    ) {
        uiView.uninstall()
    }

    private func update(_ view: NativeHorizontalChannelSwipeInstallerView) {
        view.isSwipeEnabled = isEnabled
        view.containerWidth = containerWidth
        view.onChanged = onChanged
        view.onCancelled = onCancelled
        view.onEnded = onEnded
        view.scheduleInstallation()
    }
}

private final class NativeHorizontalChannelSwipeInstallerView: UIView,
    UIGestureRecognizerDelegate {
    var isSwipeEnabled = true {
        didSet {
            guard oldValue != isSwipeEnabled else { return }
            // Disabling an active recognizer delivers one native `.cancelled` callback.
            // Let that callback reset the interactive offset instead of cancelling twice.
            panGestureRecognizer.isEnabled = isSwipeEnabled
        }
    }
    var containerWidth: CGFloat = 0
    var onChanged: ((CGSize, CGFloat) -> Void)?
    var onCancelled: (() -> Void)?
    var onEnded: ((CGSize, CGSize, CGFloat) -> Void)?

    private weak var gestureHostView: UIView?
    private var isInstallationScheduled = false
    private lazy var panGestureRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        // A committed horizontal pan must cancel the underlying row button; otherwise the
        // release can both switch channel and open the feed item below the finger.
        recognizer.cancelsTouchesInView = true
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }()

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        scheduleInstallation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleInstallation()
    }

    func scheduleInstallation() {
        guard !isInstallationScheduled else { return }
        isInstallationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isInstallationScheduled = false
            self.installIfNeeded()
        }
    }

    func uninstall() {
        gestureHostView?.removeGestureRecognizer(panGestureRecognizer)
        gestureHostView = nil
    }

    private func installIfNeeded() {
        guard window != nil, let hostView = gestureHostCandidate() else {
            uninstall()
            return
        }
        guard gestureHostView !== hostView else { return }
        uninstall()
        hostView.addGestureRecognizer(panGestureRecognizer)
        gestureHostView = hostView
    }

    private func gestureHostCandidate() -> UIView? {
        var candidate = superview
        while let parent = candidate?.superview, !(parent is UIWindow) {
            candidate = parent
        }
        return candidate
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isSwipeEnabled,
              let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let hostView = gestureHostView
        else { return false }

        let velocity = pan.velocity(in: hostView)
        guard NativeChannelSwipePolicy.shouldBegin(velocity: velocity) else { return false }

        let startLocation = convert(pan.location(in: hostView), from: hostView)
        let isInside = bounds.contains(startLocation)
        guard isInside else { return false }
        let nestedMetrics = horizontalScrollMetrics(
            at: pan.location(in: hostView),
            in: hostView
        )
        return !NativeChannelSwipeExclusionPolicy.shouldExcludeParentSwipe(
            nestedContentWidth: nestedMetrics?.contentWidth,
            nestedViewportWidth: nestedMetrics?.viewportWidth
        )
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let hostView = gestureHostView else { return }
        let translation = recognizer.translation(in: hostView)
        if recognizer.state == .changed {
            guard isSwipeEnabled else { return }
            onChanged?(CGSize(width: translation.x, height: translation.y), containerWidth)
            return
        }
        guard recognizer.state == .ended else {
            if recognizer.state == .cancelled || recognizer.state == .failed {
                onCancelled?()
            }
            return
        }
        guard isSwipeEnabled else {
            onCancelled?()
            return
        }
        let velocity = recognizer.velocity(in: hostView)
        let predictionInterval = NativeChannelSwitcherTuning.velocityPredictionInterval
        let predictedEndTranslation = CGSize(
            width: translation.x + velocity.x * predictionInterval,
            height: translation.y + velocity.y * predictionInterval
        )
        onEnded?(
            CGSize(width: translation.x, height: translation.y),
            predictedEndTranslation,
            containerWidth
        )
    }

    private func horizontalScrollMetrics(
        at location: CGPoint,
        in hostView: UIView
    ) -> (contentWidth: CGFloat, viewportWidth: CGFloat)? {
        var candidate = hostView.hitTest(location, with: nil)
        while let view = candidate, view !== hostView {
            if let scrollView = view as? UIScrollView,
               scrollView.isScrollEnabled,
               scrollView.contentSize.width > 0,
               scrollView.bounds.width > 0 {
                return (
                    scrollView.contentSize.width
                        + scrollView.adjustedContentInset.left
                        + scrollView.adjustedContentInset.right,
                    scrollView.bounds.width
                )
            }
            candidate = view.superview
        }
        return nil
    }
}

struct NativeChannelSwipeExclusionPolicy {
    static func shouldExcludeParentSwipe(
        nestedContentWidth: CGFloat?,
        nestedViewportWidth: CGFloat?
    ) -> Bool {
        guard let nestedContentWidth, let nestedViewportWidth else { return false }
        return nestedContentWidth > nestedViewportWidth
    }
}

private struct NativeChannelIsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var nativeChannelIsActive: Bool {
        get { self[NativeChannelIsActiveKey.self] }
        set { self[NativeChannelIsActiveKey.self] = newValue }
    }
}

struct NativeChannelSwipePolicy {
    static func shouldBegin(velocity: CGPoint) -> Bool {
        abs(velocity.x) > abs(velocity.y) * NativeChannelSwitcherTuning.horizontalIntentRatio
    }

    static func targetIndex(
        currentIndex: Int,
        channelCount: Int,
        translation: CGSize,
        predictedEndTranslation: CGSize,
        containerWidth: CGFloat
    ) -> Int {
        guard channelCount > 0,
              currentIndex >= 0,
              currentIndex < channelCount,
              containerWidth > 0,
              abs(translation.width) > abs(translation.height) * NativeChannelSwitcherTuning.horizontalIntentRatio
        else { return currentIndex }

        let distanceThreshold = containerWidth * NativeChannelSwitcherTuning.distanceThresholdRatio
        let projectedDistanceThreshold = distanceThreshold * NativeChannelSwitcherTuning.projectedDistanceMultiplier

        if (translation.width <= -distanceThreshold ||
            predictedEndTranslation.width <= -projectedDistanceThreshold),
           currentIndex < channelCount - 1 {
            return currentIndex + 1
        }
        if (translation.width >= distanceThreshold ||
            predictedEndTranslation.width >= projectedDistanceThreshold),
           currentIndex > 0 {
            return currentIndex - 1
        }
        return currentIndex
    }
}

private enum NativeChannelSwitcherTuning {
    // Gesture recognition and commit thresholds reuse the media gallery's existing policy.
    static let minimumDragDistance: CGFloat = 12
    static let horizontalIntentRatio: CGFloat = 1.15
    static let distanceThresholdRatio: CGFloat = 0.18
    static let projectedDistanceMultiplier: CGFloat = 1.35
    static let velocityPredictionInterval: CGFloat = 0.2

    static let selectorAnimation = Animation.easeInOut(duration: 0.22)
    static let pageAnimation = Animation.interactiveSpring(
        response: 0.32,
        dampingFraction: 0.86,
        blendDuration: 0.08
    )
}
