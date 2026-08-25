import SwiftUI

@available(iOS 16.0, *)
struct HotListNativeView: View {
    @ObservedObject private var store: HotFeedStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeChannelIsActive) private var isActiveChannel
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @State private var observedScrollToTopRequest: UInt
    @State private var lastHiddenSearchEntryTarget: NativeHomeContentScrollTarget?
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
        ScrollViewReader { proxy in
            List {
                Color.clear
                    .frame(height: 0)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .accessibilityHidden(true)
                    .id(NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .hot))

                if let onOpenSearch {
                    NativeHomeGlobalSearchEntry(action: onOpenSearch)
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
                    .listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                }

                if let errorMessage = store.errorMessage {
                    FeedRetryRow(message: errorMessage) {
                        Task { await store.retry() }
                    }
                    .id(NativeHomeContentScrollTarget.hotStatus)
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
            }
            .listStyle(.plain)
            .nativeHomeFeedListLayout()
            .refreshable {
                guard isActiveChannel else { return }
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
            .task(id: isActiveChannel) {
                guard isActiveChannel else { return }
                await store.loadInitialIfNeeded()
            }
        }
        .accessibilityIdentifier("hot_list")
    }

    private var visibleItems: [FeedItemDTO] {
        FeedQuestionAuthorVisibilityPolicy.visibleItems(
            from: store.items,
            blockedMemberIDs: questionAuthorBlocklist.blockedMemberIDs
        )
    }

    private var firstContentScrollTarget: NativeHomeContentScrollTarget? {
        visibleItems.first.map { .hot($0.id) } ?? .hotStatus
    }

    private func scrollToTop(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation {
                    if let firstContentScrollTarget {
                        proxy.scrollTo(firstContentScrollTarget, anchor: .top)
                    } else {
                        proxy.scrollTo(
                            NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .hot),
                            anchor: .top
                        )
                    }
                }
            } else if let firstContentScrollTarget {
                proxy.scrollTo(firstContentScrollTarget, anchor: .top)
            } else {
                proxy.scrollTo(
                    NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .hot),
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
