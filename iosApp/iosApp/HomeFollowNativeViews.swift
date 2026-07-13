import SwiftUI

private struct NativeRootTitleOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .nan
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct NativeRootLargeTitle: View {
    let title: String
    let coordinateSpaceName: String
    @Binding var collapseProgress: CGFloat

    init(
        _ title: String,
        coordinateSpaceName: String = "home-root-scroll",
        collapseProgress: Binding<CGFloat>
    ) {
        self.title = title
        self.coordinateSpaceName = coordinateSpaceName
        _collapseProgress = collapseProgress
    }

    var body: some View {
        Text(title)
            .font(.largeTitle.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(1 - collapseProgress)
            .offset(y: -6 * collapseProgress)
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
                collapseProgress = min(max(-minY / 44, 0), 1)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }
}

struct NativeRootCompactTitle: View {
    let title: String
    let collapseProgress: CGFloat

    init(_ title: String, collapseProgress: CGFloat) {
        self.title = title
        self.collapseProgress = collapseProgress
    }

    static func shouldRender(collapseProgress: CGFloat) -> Bool {
        collapseProgress >= 0.2
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .opacity(collapseProgress)
            .offset(y: 3 * (1 - collapseProgress))
            .accessibilityHidden(collapseProgress < 0.5)
    }
}

@available(iOS 16.0, *)
struct HomeNativeView: View {
    @StateObject private var store: HomeFeedNativeStore
    @State private var titleCollapseProgress: CGFloat = 0
    let header: HomeHeaderDTO?
    let onOpen: (FeedItemRoute) -> Void
    let onEntry: (HomeEntryIntent) -> Void

    init(
        repository: HomeFeedRepository,
        header: HomeHeaderDTO?,
        onOpen: @escaping (FeedItemRoute) -> Void,
        onEntry: @escaping (HomeEntryIntent) -> Void
    ) {
        _store = StateObject(wrappedValue: HomeFeedNativeStore(repository: repository))
        self.header = header
        self.onOpen = onOpen
        self.onEntry = onEntry
    }

    var body: some View {
        List {
            NativeRootLargeTitle("首页", collapseProgress: $titleCollapseProgress)

            if store.items.isEmpty, store.isLoading {
                HStack { Spacer(); ProgressView("正在加载推荐"); Spacer() }
                    .listRowSeparator(.hidden)
            }

            ForEach(store.items) { item in
                FeedItemRow(item: item, showsThumbnail: true) { route in
                    store.opened(item)
                    onOpen(route)
                }
            }

            if let message = store.errorMessage {
                FeedRetryRow(message: message) { Task { await store.retry() } }
            } else if store.hasNextPage {
                NativeFeedPaginationLoadingRow(title: "正在加载更多推荐")
                    .listRowSeparator(.hidden)
                    .task(id: store.nextPageLoadID) { await store.loadMore() }
            } else if store.items.isEmpty, !store.isLoading {
                Label("暂无推荐", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .coordinateSpace(name: "home-root-scroll")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .toolbar {
            if NativeRootCompactTitle.shouldRender(collapseProgress: titleCollapseProgress) {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .navigationBarLeading) {
                        NativeRootCompactTitle("首页", collapseProgress: titleCollapseProgress)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigationBarLeading) {
                        NativeRootCompactTitle("首页", collapseProgress: titleCollapseProgress)
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { onEntry(.search) } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier("home_search_entry")

                Button { onEntry(.create) } label: {
                    Label("创作", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("home_creation_entry")

                Button { onEntry(.notifications) } label: {
                    notificationIcon
                }
                .accessibilityLabel(notificationAccessibilityLabel)
                .accessibilityIdentifier("home_notifications_entry")

                Button { onEntry(.profile) } label: {
                    accountAvatar
                }
                .accessibilityLabel(header?.displayName ?? "账号")
                .accessibilityIdentifier("home_account_entry")
            }
        }
        .task { await store.loadInitialIfNeeded() }
        .accessibilityIdentifier("home_native")
    }

    private var notificationAccessibilityLabel: String {
        guard let count = header?.unreadCount, count > 0 else { return "通知" }
        return "通知，\(count) 条未读"
    }

    private var notificationIcon: some View {
        Image(systemName: "bell")
            .overlay(alignment: .topTrailing) {
                if let count = header?.unreadCount, count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .background(.red, in: Capsule())
                        .offset(x: 9, y: -8)
                }
            }
    }

    @ViewBuilder
    private var accountAvatar: some View {
        if let url = header?.avatarURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle")
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle")
        }
    }
}

struct FollowNativeView: View {
    @StateObject private var store: FollowNativeStore
    let onOpen: (FeedItemRoute) -> Void
    let onOpenPerson: (PersonRoutePayload) -> Void

    init(
        repository: FollowRepository,
        onOpen: @escaping (FeedItemRoute) -> Void,
        onOpenPerson: @escaping (PersonRoutePayload) -> Void
    ) {
        _store = StateObject(wrappedValue: FollowNativeStore(repository: repository))
        self.onOpen = onOpen
        self.onOpenPerson = onOpenPerson
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("关注内容", selection: sectionBinding) {
                ForEach(FollowSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            TabView(selection: sectionBinding) {
                followList(section: .recommendations)
                    .tag(FollowSection.recommendations)
                followList(section: .moments)
                    .tag(FollowSection.moments)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("关注")
        .task { await store.loadInitialIfNeeded() }
        .accessibilityIdentifier("follow_native")
    }

    private func followList(section: FollowSection) -> some View {
        let page = section == .recommendations ? store.recommendations : store.moments
        return List {
            if section == .recommendations { recentUsers }

            if page.items.isEmpty, page.isLoading {
                HStack { Spacer(); ProgressView("正在加载关注内容"); Spacer() }
                    .listRowSeparator(.hidden)
            }

            ForEach(page.items) { item in
                FeedItemRow(item: item, showsThumbnail: true, onOpen: onOpen)
            }

            if let message = page.errorMessage {
                FeedRetryRow(message: message) {
                    Task { await store.retry(section: section) }
                }
            } else if page.hasNextPage {
                NativeFeedPaginationLoadingRow(title: "正在加载更多关注内容")
                    .listRowSeparator(.hidden)
                    .task(id: page.nextPageLoadID) { await store.loadMore(section: section) }
            } else if page.items.isEmpty, !page.isLoading {
                Label("暂无关注内容", systemImage: "person.2")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refresh(section: section) }
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
            }
        }
    }

    private var sectionBinding: Binding<FollowSection> {
        Binding(
            get: { store.selectedSection },
            set: { section in
                store.select(section)
                Task { await store.loadIfNeeded(section: section) }
            }
        )
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
