import SwiftUI
import UIKit

struct QAReadingPreferences: Equatable {
    let pinAnswerDate: Bool
    let answerSwitchEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        pinAnswerDate = defaults.bool(forKey: "pinAnswerDate")
        answerSwitchEnabled = defaults.string(forKey: "answerSwitchMode") != "off"
    }
}

struct NativeAnswerPager: View {
    @ObservedObject var store: AnswerPagerStore
    let preferences: QAReadingPreferences
    let onNavigate: (QANavigationIntent) -> Void

    var body: some View {
        QAAnswerPagerSurface(
            pager: store,
            answer: store.current,
            preferences: preferences,
            onNavigate: onNavigate
        )
        .task { await store.prepare() }
    }
}

private struct QAAnswerPagerSurface: View {
    @ObservedObject var pager: AnswerPagerStore
    @ObservedObject var answer: AnswerStore
    let preferences: QAReadingPreferences
    let onNavigate: (QANavigationIntent) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            QAAnswerPageController(
                pager: pager,
                pinAnswerDate: preferences.pinAnswerDate,
                answerSwitchEnabled: preferences.answerSwitchEnabled,
                onNavigate: onNavigate
            )
            if let error = pager.switchError {
                Button {
                    Task { await pager.retrySwitch() }
                } label: {
                    Label("下一个回答加载失败，点此重试", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint(error)
                .padding(.top, 8)
            } else if let notice = pager.boundaryNotice {
                Text(notice)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityAddTraits(.isStaticText)
                    .padding(.top, 8)
            }
        }
        .navigationTitle(answer.initialRoute.kind == .answer ? "回答" : "文章")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let content = answer.content {
                    Menu {
                        Button {
                            onNavigate(.share(content.sourceURL))
                        } label: {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.url = content.sourceURL
                        } label: {
                            Label("复制链接", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .background(NativeAnswerInteractivePopBridge())
    }
}

private struct NativeAnswerInteractivePopBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> NativeAnswerInteractivePopObserverController {
        NativeAnswerInteractivePopObserverController()
    }

    func updateUIViewController(
        _ uiViewController: NativeAnswerInteractivePopObserverController,
        context: Context
    ) {}
}

private final class NativeAnswerInteractivePopObserverController: UIViewController,
    UIGestureRecognizerDelegate
{
    private weak var observedGesture: UIGestureRecognizer?
    private weak var previousDelegate: UIGestureRecognizerDelegate?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let navigationController,
              navigationController.viewControllers.count > 1,
              let gesture = navigationController.interactivePopGestureRecognizer
        else { return }
        observedGesture = gesture
        previousDelegate = gesture.delegate
        gesture.delegate = self
        gesture.isEnabled = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if observedGesture?.delegate === self {
            observedGesture?.delegate = previousDelegate
        }
        observedGesture = nil
        previousDelegate = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        navigationController?.viewControllers.count ?? 0 > 1
    }
}

private struct QAAnswerPageController: UIViewControllerRepresentable {
    @ObservedObject var pager: AnswerPagerStore
    let pinAnswerDate: Bool
    let answerSwitchEnabled: Bool
    let onNavigate: (QANavigationIntent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pager: pager,
            pinAnswerDate: pinAnswerDate,
            answerSwitchEnabled: answerSwitchEnabled,
            onNavigate: onNavigate
        )
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .systemBackground
        controller.setViewControllers(
            [context.coordinator.controller(for: pager.current)],
            direction: .forward,
            animated: false
        )
        context.coordinator.recordPagingAvailability()
        DispatchQueue.main.async {
            context.coordinator.establishSystemEdgePrecedence(in: controller)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.pager = pager
        context.coordinator.onNavigate = onNavigate
        context.coordinator.updatePinAnswerDate(pinAnswerDate)
        context.coordinator.updateAnswerSwitchEnabled(answerSwitchEnabled)
        context.coordinator.establishSystemEdgePrecedence(in: controller)
        guard let visible = controller.viewControllers?.first as? QAHostedAnswerController else { return }
        if visible.answerID != pager.current.id, !context.coordinator.isTransitioning {
            controller.setViewControllers(
                [context.coordinator.controller(for: pager.current)],
                direction: .forward,
                animated: false
            )
            context.coordinator.recordPagingAvailability()
        } else {
            context.coordinator.refreshPagingAvailabilityIfNeeded(in: controller, visible: visible)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate
    {
        var pager: AnswerPagerStore
        var pinAnswerDate: Bool
        var answerSwitchEnabled: Bool
        var onNavigate: (QANavigationIntent) -> Void
        var isTransitioning = false
        private var controllers: [Int64: QAHostedAnswerController] = [:]
        private weak var relatedNavigationController: UINavigationController?
        private weak var relatedPagingPan: UIPanGestureRecognizer?
        private weak var pagingPanGesture: UIPanGestureRecognizer?
        private weak var pageController: UIPageViewController?
        private weak var pagingScrollView: UIScrollView?
        private var recordedCurrentID: Int64?
        private var recordedPreviousID: Int64?
        private var recordedNextID: Int64?

        init(
            pager: AnswerPagerStore,
            pinAnswerDate: Bool,
            answerSwitchEnabled: Bool,
            onNavigate: @escaping (QANavigationIntent) -> Void
        ) {
            self.pager = pager
            self.pinAnswerDate = pinAnswerDate
            self.answerSwitchEnabled = answerSwitchEnabled
            self.onNavigate = onNavigate
        }

        func controller(for store: AnswerStore) -> QAHostedAnswerController {
            if let cached = controllers[store.id] { return cached }
            let root = hostedRoot(for: store)
            let created = QAHostedAnswerController(answerID: store.id, rootView: root)
            created.view.backgroundColor = .systemBackground
            controllers[store.id] = created
            return created
        }

        func refreshHostedRoots() {
            for controller in controllers.values {
                controller.rootView = hostedRoot(for: controller.rootView.store)
            }
        }

        func updatePinAnswerDate(_ value: Bool) {
            guard pinAnswerDate != value else { return }
            pinAnswerDate = value
            refreshHostedRoots()
        }

        func updateAnswerSwitchEnabled(_ value: Bool) {
            guard answerSwitchEnabled != value else { return }
            answerSwitchEnabled = value
            pagingScrollView?.isScrollEnabled = value
        }

        func recordPagingAvailability() {
            recordedCurrentID = pager.current.id
            recordedPreviousID = pager.previous?.id
            recordedNextID = pager.next?.id
        }

        func refreshPagingAvailabilityIfNeeded(
            in pageController: UIPageViewController,
            visible: QAHostedAnswerController
        ) {
            let availabilityChanged = recordedCurrentID != pager.current.id ||
                recordedPreviousID != pager.previous?.id ||
                recordedNextID != pager.next?.id
            guard !isTransitioning,
                  visible.answerID == pager.current.id,
                  availabilityChanged,
                  pagingPanGesture?.state != .began,
                  pagingPanGesture?.state != .changed
            else { return }
            pageController.setViewControllers(
                [visible],
                direction: .forward,
                animated: false
            )
            recordPagingAvailability()
        }

        private func hostedRoot(for store: AnswerStore) -> AnswerNativeView {
            AnswerNativeView(
                store: store,
                pinAnswerDate: pinAnswerDate,
                onNavigate: { [weak self] intent in self?.onNavigate(intent) }
            )
        }

        func establishSystemEdgePrecedence(in pageController: UIPageViewController) {
            self.pageController = pageController
            guard let pagingScrollView = pageController.view.subviews
                .compactMap({ $0 as? UIScrollView })
                .first
            else { return }
            self.pagingScrollView = pagingScrollView
            pagingScrollView.isScrollEnabled = answerSwitchEnabled
            let pagePan = pagingScrollView.panGestureRecognizer

            if pagingPanGesture !== pagePan {
                pagingPanGesture?.removeTarget(self, action: #selector(handlePagePan(_:)))
                pagePan.addTarget(self, action: #selector(handlePagePan(_:)))
                pagingPanGesture = pagePan
            }

            guard let navigationController = pageController.navigationController,
                  let interactivePop = navigationController.interactivePopGestureRecognizer
            else { return }
            guard relatedNavigationController !== navigationController || relatedPagingPan !== pagePan else { return }
            if navigationController.viewControllers.count > 1 {
                interactivePop.isEnabled = true
            }
            pagePan.require(toFail: interactivePop)
            relatedNavigationController = navigationController
            relatedPagingPan = pagePan
        }

        @objc private func handlePagePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended || gesture.state == .cancelled else { return }
            defer {
                if let pageController,
                   let visible = pageController.viewControllers?.first as? QAHostedAnswerController
                {
                    refreshPagingAvailabilityIfNeeded(in: pageController, visible: visible)
                }
            }
            guard gesture.state == .ended else { return }
            let translation = gesture.translation(in: gesture.view)
            guard abs(translation.x) > 72, abs(translation.x) > abs(translation.y),
                  pager.current.initialRoute.kind == .answer
            else { return }
            if translation.x < 0, case .end = pager.forwardAvailability {
                pager.reportForwardBoundaryReached()
            }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let visible = viewController as? QAHostedAnswerController,
                  visible.answerID == pager.current.id
            else { return nil }
            if let previous = pager.previous {
                return controller(for: previous)
            }
            return nil
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let visible = viewController as? QAHostedAnswerController,
                  visible.answerID == pager.current.id,
                  let next = pager.next
            else { return nil }
            return controller(for: next)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isTransitioning = true
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            isTransitioning = false
            guard completed, let visible = pageViewController.viewControllers?.first else { return }
            guard let visible = visible as? QAHostedAnswerController else { return }
            guard pager.commitDisplayedAnswer(answerID: visible.answerID) else { return }
            recordPagingAvailability()
            Task { await pager.prepareDisplayedAnswer() }
        }
    }
}

private final class QAHostedAnswerController: UIHostingController<AnswerNativeView> {
    let answerID: Int64

    init(answerID: Int64, rootView: AnswerNativeView) {
        self.answerID = answerID
        super.init(rootView: rootView)
    }

    @MainActor required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
