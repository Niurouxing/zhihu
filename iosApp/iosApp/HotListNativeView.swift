import SwiftUI

@available(iOS 16.0, *)
struct HotListNativeView: View {
    @ObservedObject private var store: HotFeedStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeChannelIsActive) private var isActiveChannel
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
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
        self.scrollToTopRequest = scrollToTopRequest
        self.onOpenSearch = onOpenSearch
        self.onOpen = onOpen
    }

    var body: some View {
        let items = visibleItems
        NativeHomeChannelScrollView(
            channel: .hot,
            isActive: isActiveChannel,
            scrollToTopRequest: scrollToTopRequest,
            isRefreshing: store.isRefreshing,
            onOpenSearch: onOpenSearch,
            onRefresh: refresh
        ) {
            if store.items.isEmpty, store.isLoading {
                HStack {
                    Spacer()
                    ProgressView("正在加载热榜")
                    Spacer()
                }
            }

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                FeedItemRow(
                    item: item,
                    showsThumbnail: false,
                    rank: index + 1,
                    onOpen: onOpen
                )
                .nativeFeedCardItemLayout()
            }

            if let errorMessage = store.errorMessage {
                FeedRetryRow(message: errorMessage) {
                    Task { await store.retry() }
                }
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
                .task(id: taskID) {
                    guard taskID.isActive,
                          taskID.value == store.nextPageLoadID
                    else { return }
                    await store.loadNextPage()
                }
            } else if items.isEmpty, !store.isLoading {
                Label("暂无热榜", systemImage: "flame")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: isActiveChannel) {
            guard isActiveChannel else { return }
            await store.loadInitialIfNeeded()
        }
        .accessibilityIdentifier("hot_list")
    }

    private var visibleItems: [FeedItemDTO] {
        FeedQuestionAuthorVisibilityPolicy.visibleItems(
            from: store.items,
            blockedMemberIDs: questionAuthorBlocklist.blockedMemberIDs
        )
    }

    private func refresh() async {
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
}
