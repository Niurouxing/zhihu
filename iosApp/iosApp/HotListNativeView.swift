import SwiftUI

@available(iOS 16.0, *)
struct HotListNativeView: View {
    @StateObject private var store: HotFeedStore
    @State private var titleCollapseProgress: CGFloat = 0
    private let onOpen: (FeedItemRoute) -> Void

    init(repository: HotFeedRepository, onOpen: @escaping (FeedItemRoute) -> Void) {
        _store = StateObject(wrappedValue: HotFeedStore(repository: repository))
        self.onOpen = onOpen
    }

    var body: some View {
        List {
            NativeRootLargeTitle(
                "热榜",
                coordinateSpaceName: "hot-root-scroll",
                collapseProgress: $titleCollapseProgress
            )

            if store.items.isEmpty, store.isLoading {
                HStack {
                    Spacer()
                    ProgressView("正在加载热榜")
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }

            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(index < 3 ? Color.accentColor : Color.secondary)
                        .frame(minWidth: 26, alignment: .trailing)
                        .padding(.top, 5)
                        .accessibilityHidden(true)
                    FeedItemRow(item: item, showsThumbnail: false, onOpen: onOpen)
                }
            }

            if let errorMessage = store.errorMessage {
                FeedRetryRow(message: errorMessage) {
                    Task { await store.retry() }
                }
            } else if store.canLoadNextPage {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .task { await store.loadNextPage() }
            }
        }
        .listStyle(.plain)
        .coordinateSpace(name: "hot-root-scroll")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if NativeRootCompactTitle.shouldRender(collapseProgress: titleCollapseProgress) {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .navigationBarLeading) {
                        NativeRootCompactTitle("热榜", collapseProgress: titleCollapseProgress)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigationBarLeading) {
                        NativeRootCompactTitle("热榜", collapseProgress: titleCollapseProgress)
                    }
                }
            }
        }
        .refreshable { await store.refresh() }
        .task { await store.loadInitialIfNeeded() }
        .accessibilityIdentifier("hot_list")
    }
}
