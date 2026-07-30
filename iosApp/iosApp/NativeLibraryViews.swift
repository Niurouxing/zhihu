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
            if store.canLoadMore {
                NativePaginationFooter(
                    isLoading: store.isLoadingMore,
                    accessibilityIdentifier: "native_history_pagination_footer"
                )
                .task { await store.loadMore() }
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

struct NativeSpecialView: View {
    @StateObject private var store: NativeSpecialStore
    let onOpenContent: (FeedItemRoute) -> Void

    init(
        specialID: String,
        repository: NativeSpecialRepository,
        onOpenContent: @escaping (FeedItemRoute) -> Void
    ) {
        _store = StateObject(wrappedValue: NativeSpecialStore(
            specialID: specialID,
            repository: repository
        ))
        self.onOpenContent = onOpenContent
    }

    var body: some View {
        ScrollView {
            if let special = store.special {
                LazyVStack(alignment: .leading, spacing: 0) {
                    NativeSpecialHeader(special: special)
                    if let error = store.errorMessage {
                        NativeInlineRetry(message: error) {
                            Task { await store.refresh() }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 8)
                    }
                    if special.sections.isEmpty {
                        NativeUnavailableState(
                            title: "专题暂无内容",
                            message: "知乎暂时没有返回可展示的专题内容"
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(special.groups) { group in
                            NativeSpecialGroupView(group: group, onOpenContent: onOpenContent)
                        }
                    }
                }
                .padding(.bottom, 28)
            }
        }
        .accessibilityIdentifier("native_special_screen")
        .navigationTitle(store.special?.title ?? "收录专题")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .overlay { initialState }
        .task {
            if store.special == nil, !store.isLoading {
                await store.refresh()
            }
        }
    }

    @ViewBuilder private var initialState: some View {
        if store.isLoading, store.special == nil {
            ProgressView("正在加载专题")
        } else if let error = store.errorMessage, store.special == nil {
            NativeUnavailableState(
                title: "无法加载专题",
                message: error,
                actionTitle: "重试"
            ) {
                Task { await store.refresh() }
            }
        }
    }
}

struct NativeColumnView: View {
    @StateObject private var store: NativeColumnStore
    let onOpenContent: (NativeContentDestination) -> Void

    init(
        columnID: String,
        repository: NativeColumnRepository,
        onOpenContent: @escaping (NativeContentDestination) -> Void
    ) {
        _store = StateObject(wrappedValue: NativeColumnStore(
            columnID: columnID,
            repository: repository
        ))
        self.onOpenContent = onOpenContent
    }

    var body: some View {
        List {
            if let column = store.column {
                NativeColumnHeader(column: column)
                    .listRowSeparator(.hidden)
            }
            if let error = store.errorMessage, !store.items.isEmpty {
                NativeInlineRetry(message: error) { Task { await store.loadMore() } }
            }
            ForEach(store.items) { item in
                NativeLibraryItemRow(item: item, onOpenContent: onOpenContent)
            }
            if store.canLoadMore {
                NativePaginationFooter(
                    isLoading: store.isLoadingMore,
                    accessibilityIdentifier: "native_column_pagination_footer"
                )
                    .task { await store.loadMore() }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("native_column_screen")
        .navigationTitle(store.column?.title ?? "专栏")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .overlay { initialState }
        .task {
            if store.items.isEmpty, !store.isLoading { await store.refresh() }
        }
    }

    @ViewBuilder private var initialState: some View {
        if store.isLoading, store.items.isEmpty {
            ProgressView("正在加载专栏")
        } else if let error = store.errorMessage, store.items.isEmpty {
            NativeUnavailableState(
                title: "无法加载专栏",
                message: error,
                actionTitle: "重试"
            ) {
                Task { await store.refresh() }
            }
        } else if store.items.isEmpty, store.column != nil {
            NativeUnavailableState(title: "专栏暂无内容", message: "这里暂时没有可显示的内容")
        }
    }
}

private struct NativePaginationFooter: View {
    let isLoading: Bool
    let accessibilityIdentifier: String

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(height: 52)
            }
            Divider()
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct NativeColumnHeader: View {
    let column: NativeColumnDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if let imageURL = column.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        if case let .success(image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.1)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(column.title)
                        .font(.title2.weight(.bold))
                    if let author = column.author, !author.name.isEmpty {
                        Text(author.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !column.description.isEmpty {
                Text(column.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(
                "\(column.itemCount.formatted(.number.notation(.compactName))) 篇内容"
                    + " · \(column.followersCount.formatted(.number.notation(.compactName))) 人关注"
                    + " · \(column.voteupCount.formatted(.number.notation(.compactName))) 赞同"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private struct NativeSpecialHeader: View {
    let special: NativeSpecialDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let bannerURL = special.bannerURL {
                AsyncImage(url: bannerURL) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ZStack {
                            Color.secondary.opacity(0.08)
                            ProgressView()
                        }
                    case .failure:
                        Color.secondary.opacity(0.08)
                    @unknown default:
                        Color.secondary.opacity(0.08)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(special.title)
                    .font(.title2.weight(.bold))
                if !special.introduction.isEmpty {
                    Text(special.introduction)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    NativeSpecialMetric(value: special.contentCount, label: "条内容")
                    NativeSpecialMetric(value: special.viewCount, label: "次浏览")
                    NativeSpecialMetric(value: special.followersCount, label: "人关注")
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.bottom, 20)
    }
}

private struct NativeSpecialMetric: View {
    let value: Int
    let label: String

    var body: some View {
        Text("\(value.formatted(.number.notation(.compactName))) \(label)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct NativeSpecialGroupView: View {
    let group: NativeSpecialGroup
    let onOpenContent: (FeedItemRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !group.title.isEmpty {
                Text(group.title)
                    .font(.title2.weight(.bold))
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 4)
            }
            ForEach(group.sections) { section in
                NativeSpecialSectionView(section: section, onOpenContent: onOpenContent)
            }
        }
    }
}

private struct NativeSpecialSectionView: View {
    let section: NativeSpecialSection
    let onOpenContent: (FeedItemRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !section.title.isEmpty {
                Text(section.title)
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
            }
            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                NativeSpecialItemRow(item: item, onOpenContent: onOpenContent)
                    .padding(.horizontal, 18)
                if index < section.items.count - 1 {
                    Divider().padding(.leading, 18)
                }
            }
        }
    }
}

private struct NativeSpecialItemRow: View {
    let item: NativeSpecialItem
    let onOpenContent: (FeedItemRoute) -> Void

    var body: some View {
        Group {
            if let route = item.route {
                Button {
                    onOpenContent(route)
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .accessibilityIdentifier("native_special_item_\(item.id)")
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if !item.excerpt.isEmpty {
                        Text(item.excerpt)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let imageURL = item.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        if case let .success(image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.1)
                        }
                    }
                    .frame(width: 96, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }

            HStack(spacing: 6) {
                if let authorName = item.authorName, !authorName.isEmpty {
                    Text(authorName)
                }
                Spacer(minLength: 8)
                Text(itemMetadata)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var itemMetadata: String {
        let metrics = item.tags
            .filter { !$0.name.isEmpty }
            .map { "\($0.value.formatted(.number.notation(.compactName))) \($0.name)" }
            .joined(separator: " · ")
        return [metrics, item.contentTypeLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

private struct NativeLibraryItemRow: View {
    let item: NativeLibraryItem
    let onOpenContent: (NativeContentDestination) -> Void

    var body: some View {
        Group {
            if let destination = item.destination {
                Button { onOpenContent(destination) } label: { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
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
    }
}

private struct NativeHistoryRow: View {
    let item: NativeHistoryItem
    let onOpenContent: (NativeContentDestination) -> Void

    var body: some View {
        Group {
            if let destination = item.destination {
                Button { onOpenContent(destination) } label: { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
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
