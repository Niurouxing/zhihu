import SwiftUI

@available(iOS 16.0, *)
struct NativeCollectionsView: View {
    @StateObject private var store: NativeCollectionsStore
    let onOpenContent: (NativeContentDestination) -> Void

    init(
        userToken: String,
        repository: NativeLibraryRepository,
        onOpenContent: @escaping (NativeContentDestination) -> Void
    ) {
        _store = StateObject(wrappedValue: NativeCollectionsStore(userToken: userToken, repository: repository))
        self.onOpenContent = onOpenContent
    }

    var body: some View {
        List {
            if let error = store.errorMessage, !store.collections.isEmpty {
                NativeInlineRetry(message: error) { Task { await store.loadMore() } }
            }
            ForEach(store.collections) { collection in
                NavigationLink(value: NativeShellRoute.collectionContent(collection.id)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(collection.title).font(.headline)
                        if !collection.description.isEmpty {
                            Text(collection.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text("\(collection.itemCount) 条收藏 · \(collection.likeCount) 个赞同")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            paginationFooter
        }
        .listStyle(.plain)
        .navigationTitle("我的收藏夹")
        .refreshable { await store.refresh() }
        .overlay { initialState }
        .task {
            if store.collections.isEmpty, !store.isLoading { await store.refresh() }
        }
    }

    @ViewBuilder private var paginationFooter: some View {
        if store.isLoading, !store.collections.isEmpty {
            HStack { Spacer(); ProgressView(); Spacer() }
        } else if !store.isEnd, !store.collections.isEmpty {
            Color.clear.frame(height: 1).task { await store.loadMore() }
        }
    }

    @ViewBuilder private var initialState: some View {
        if store.isLoading, store.collections.isEmpty {
            ProgressView("正在加载收藏夹")
        } else if let error = store.errorMessage, store.collections.isEmpty {
            NativeUnavailableState(title: "无法加载收藏夹", message: error, actionTitle: "重试") {
                Task { await store.refresh() }
            }
        } else if store.collections.isEmpty {
            NativeUnavailableState(title: "还没有收藏夹", message: "收藏的内容会显示在这里")
        }
    }
}

struct NativeCollectionContentView: View {
    @StateObject private var store: NativeCollectionContentStore
    let onOpenContent: (NativeContentDestination) -> Void

    init(
        collectionID: String,
        repository: NativeLibraryRepository,
        onOpenContent: @escaping (NativeContentDestination) -> Void
    ) {
        _store = StateObject(wrappedValue: NativeCollectionContentStore(collectionID: collectionID, repository: repository))
        self.onOpenContent = onOpenContent
    }

    var body: some View {
        List {
            if let collection = store.collection {
                Section {
                    Text("\(collection.itemCount) 条收藏 · \(collection.likeCount) 个赞同 · \(collection.commentCount) 条评论")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let error = store.errorMessage, !store.items.isEmpty {
                NativeInlineRetry(message: error) { Task { await store.loadMore() } }
            }
            ForEach(store.items) { item in
                NativeLibraryItemRow(item: item, onOpenContent: onOpenContent)
            }
            if store.isLoading, !store.items.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if !store.isEnd, !store.items.isEmpty {
                Color.clear.frame(height: 1).task { await store.loadMore() }
            }
        }
        .listStyle(.plain)
        .navigationTitle(store.collection?.title ?? "收藏夹")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .overlay { initialState }
        .task {
            if store.items.isEmpty, !store.isLoading { await store.refresh() }
        }
    }

    @ViewBuilder private var initialState: some View {
        if store.isLoading, store.items.isEmpty {
            ProgressView("正在加载收藏内容")
        } else if let error = store.errorMessage, store.items.isEmpty {
            NativeUnavailableState(title: "无法加载收藏内容", message: error, actionTitle: "重试") {
                Task { await store.refresh() }
            }
        } else if store.items.isEmpty {
            NativeUnavailableState(title: "收藏夹为空", message: "这里暂时没有可显示的内容")
        }
    }
}

struct NativeHistoryView: View {
    @StateObject private var store: NativeHistoryStore
    let onOpenContent: (NativeContentDestination) -> Void

    @State private var confirmsClear = false
    @State private var clearSucceeded = false

    init(repository: NativeLibraryRepository, onOpenContent: @escaping (NativeContentDestination) -> Void) {
        _store = StateObject(wrappedValue: NativeHistoryStore(repository: repository))
        self.onOpenContent = onOpenContent
    }

    var body: some View {
        List {
            if let error = store.errorMessage, !store.items.isEmpty {
                NativeInlineRetry(message: error) { Task { await store.loadMore() } }
            }
            ForEach(store.items) { item in
                NativeHistoryRow(item: item, onOpenContent: onOpenContent)
            }
            if store.isLoading, !store.items.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if !store.isEnd, !store.items.isEmpty {
                Color.clear.frame(height: 1).task { await store.loadMore() }
            }
        }
        .listStyle(.plain)
        .navigationTitle("历史记录")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        confirmsClear = true
                    } label: {
                        Label("清除历史记录", systemImage: "trash")
                    }
                    .disabled(store.items.isEmpty || store.isClearing)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable { await store.refresh() }
        .overlay { initialState }
        .task {
            if store.items.isEmpty, !store.isLoading { await store.refresh() }
        }
        .alert("确认清除历史记录", isPresented: $confirmsClear) {
            Button("我再想想", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task { clearSucceeded = await store.clear() }
            }
        } message: {
            Text("此操作会清除当前知乎账号的在线浏览历史。")
        }
        .alert("历史记录已清除", isPresented: $clearSucceeded) {
            Button("好", role: .cancel) {}
        }
    }

    @ViewBuilder private var initialState: some View {
        if store.isLoading, store.items.isEmpty {
            ProgressView("正在加载历史记录")
        } else if let error = store.errorMessage, store.items.isEmpty {
            NativeUnavailableState(title: "无法加载历史记录", message: error, actionTitle: "重试") {
                Task { await store.refresh() }
            }
        } else if store.items.isEmpty {
            NativeUnavailableState(title: "暂无历史记录", message: "浏览过的内容会显示在这里")
        }
    }
}

private struct NativeLibraryItemRow: View {
    let item: NativeLibraryItem
    let onOpenContent: (NativeContentDestination) -> Void

    var body: some View {
        Group {
            if let destination = item.destination {
                Button { onOpenContent(destination) } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            if item.avatarURL != nil {
                AsyncImage(url: item.avatarURL) { phase in
                    if case let .success(image) = phase { image.resizable().scaledToFill() }
                    else { Color.secondary.opacity(0.15) }
                }
                .frame(width: 38, height: 38).clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.headline).foregroundStyle(.primary)
                if !item.summary.isEmpty {
                    Text(item.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private struct NativeHistoryRow: View {
    let item: NativeHistoryItem
    let onOpenContent: (NativeContentDestination) -> Void

    var body: some View {
        Group {
            if let destination = item.destination {
                Button { onOpenContent(destination) } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.headline).foregroundStyle(.primary)
                if !item.summary.isEmpty {
                    Text(item.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
                Text([item.authorName, item.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if item.coverURL != nil {
                AsyncImage(url: item.coverURL) { phase in
                    if case let .success(image) = phase { image.resizable().scaledToFill() }
                    else { Color.secondary.opacity(0.12) }
                }
                .frame(width: 72, height: 54).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

struct NativeInlineRetry: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("重试", action: retry).font(.footnote.weight(.semibold))
        }
    }
}

struct NativeUnavailableState: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
    }
}
