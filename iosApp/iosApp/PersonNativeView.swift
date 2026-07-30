import SwiftUI
import UIKit

struct PersonNativeView: View {
    @ObservedObject private var model: PersonHostModel
    @ObservedObject private var store: PersonStore
    @State private var sheet: PersonSheetDestination?
    @State private var listScrollView: UIScrollView?

    init(model: PersonHostModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.store)
    }

    var body: some View {
        List {
            profileSection
            Section {
                pageContent
            } header: {
                VStack(spacing: 0) {
                    PersonTabSelector(selection: store.selectedTab, onSelect: selectTab)
                    if store.selectedTab == .subscriptions {
                        PersonSubscriptionTabSelector(
                            selection: store.selectedSubscriptionTab,
                            onSelect: selectSubscriptionTab
                        )
                    }
                }
                .textCase(nil)
            }
        }
        .listStyle(.plain)
        .background(PersonScrollViewAccessor { listScrollView = $0 })
        .refreshable { await store.refreshVisiblePage() }
        .navigationTitle(store.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(item: $sheet) { destination in
            PersonSheetView(destination: destination)
        }
        .task { store.start() }
        .accessibilityIdentifier("person_native_view")
    }

    @ViewBuilder
    private var profileSection: some View {
        Section {
            switch store.profileState {
            case let .idle(provisionalDisplayName):
                PersonProfilePlaceholder(displayName: provisionalDisplayName)
                    .redacted(reason: .placeholder)
            case let .loading(previous):
                if let previous { profileHeader(previous) } else {
                    PersonProfilePlaceholder(displayName: store.navigationTitle)
                        .redacted(reason: .placeholder)
                }
                HStack { Spacer(); ProgressView("正在更新资料"); Spacer() }
                    .font(.caption)
            case let .loaded(profile):
                profileHeader(profile)
            case let .failed(error, previous):
                if let previous { profileHeader(previous) }
                InlinePersonFailure(message: error.message, retryTitle: "重新加载用户资料", retry: store.retryProfile)
            }
        }
        .listRowSeparator(.hidden)
    }

    private func profileHeader(_ profile: PersonProfile) -> some View {
        PersonProfileHeader(
            profile: profile,
            followState: store.followAction,
            blockState: store.blockAction,
            onSelectTab: store.selectTab,
            onFollow: store.toggleFollow,
            onRetryFollow: store.retryFollow,
            onBlock: store.toggleBlock,
            onRetryBlock: store.retryBlock,
            onAvatar: { sheet = .avatar($0, profile.displayName) },
            onBadges: { sheet = .badges($0) }
        )
    }

    @ViewBuilder
    private var pageContent: some View {
        if let sort = store.sortByTab[store.selectedTab] {
            PersonSortControl(selection: sort, onSelect: store.changeSort)
                .listRowSeparator(.hidden)
        }

        let page = store.visiblePage
        switch page.initialLoad {
        case .idle where page.items.isEmpty, .loading where page.items.isEmpty:
            ForEach(0..<4, id: \.self) { _ in
                PersonRowPlaceholder().redacted(reason: .placeholder)
            }
        case let .failed(error) where page.items.isEmpty:
            PersonUnavailableContent(
                title: "内容加载失败",
                message: error.message,
                systemImage: "wifi.exclamationmark",
                actionTitle: "重试",
                action: store.retryInitialPage
            )
            .listRowSeparator(.hidden)
        case .loaded where page.items.isEmpty:
            PersonUnavailableContent(
                title: "暂无内容",
                message: "这里还没有公开内容",
                systemImage: "tray",
                actionTitle: nil,
                action: nil
            )
            .listRowSeparator(.hidden)
        default:
            if case let .failed(error) = page.initialLoad {
                InlinePersonFailure(message: error.message, retryTitle: "重新加载当前列表", retry: store.retryInitialPage)
            }
            ForEach(page.items) { item in
                PersonPageRow(item: item) { store.open(item) }
                    .id(item.id)
                    .onAppear { store.loadNextPageIfNeeded(after: item.id) }
            }
            pageFooter(page)
        }
    }

    @ViewBuilder
    private func pageFooter(_ page: PersonPageState) -> some View {
        switch page.nextPage {
        case .loading:
            HStack { Spacer(); ProgressView("正在加载更多"); Spacer() }
                .font(.caption)
                .listRowSeparator(.hidden)
        case let .failed(error):
            InlinePersonFailure(message: error.message, retryTitle: "重新加载更多内容", retry: store.retryNextPage)
                .listRowSeparator(.hidden)
        case .idle where page.isEnd && !page.items.isEmpty:
            Text("已经到底了")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        default:
            EmptyView()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if store.profile?.memberScopedSearchID != nil {
                    Button(action: store.openMemberSearch) {
                        Label("搜索 TA 的创作", systemImage: "magnifyingglass")
                    }
                }
                if store.profile != nil {
                    Button(action: store.openProfileInWeb) {
                        Label("在知乎网页中打开", systemImage: "safari")
                    }
                }
                if store.profile != nil {
                    Divider()
                    if store.profile?.isBlocking == true {
                        Button(action: store.toggleBlock) {
                            Label("取消拉黑", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .disabled(store.blockAction.isInFlight)
                    } else {
                        Button(role: .destructive, action: store.toggleBlock) {
                            Label("拉黑", systemImage: "person.crop.circle.badge.xmark")
                        }
                        .disabled(store.blockAction.isInFlight)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("用户主页更多操作")
        }
    }

    private func selectTab(_ tab: PersonTab) {
        let contentOffset = listScrollView?.contentOffset
        store.selectTab(tab)
        guard !tab.isConnectionList else { return }
        restoreListPosition(contentOffset)
    }

    private func selectSubscriptionTab(_ tab: PersonSubscriptionTab) {
        let contentOffset = listScrollView?.contentOffset
        store.selectSubscriptionTab(tab)
        restoreListPosition(contentOffset)
    }

    private func restoreListPosition(_ contentOffset: CGPoint?) {
        guard let contentOffset else { return }
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                guard let scrollView = listScrollView else { return }
                let minimum = -scrollView.adjustedContentInset.top
                let maximum = max(
                    minimum,
                    scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
                )
                scrollView.setContentOffset(
                    CGPoint(x: contentOffset.x, y: min(maximum, max(minimum, contentOffset.y))),
                    animated: false
                )
            }
        }
    }
}

struct PersonConnectionsView: View {
    @ObservedObject private var model: PersonHostModel
    @ObservedObject private var store: PersonStore
    let title: String

    init(model: PersonHostModel, title: String) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.store)
        self.title = title
    }

    var body: some View {
        List {
            pageContent
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshVisiblePage() }
        .task { store.start() }
        .accessibilityIdentifier("person_connections_view")
    }

    @ViewBuilder
    private var pageContent: some View {
        let page = store.visiblePage
        switch page.initialLoad {
        case .idle where page.items.isEmpty, .loading where page.items.isEmpty:
            ForEach(0..<6, id: \.self) { _ in
                PersonRowPlaceholder().redacted(reason: .placeholder)
            }
        case let .failed(error) where page.items.isEmpty:
            PersonUnavailableContent(
                title: "内容加载失败",
                message: error.message,
                systemImage: "wifi.exclamationmark",
                actionTitle: "重试",
                action: store.retryInitialPage
            )
            .listRowSeparator(.hidden)
        case .loaded where page.items.isEmpty:
            PersonUnavailableContent(
                title: "暂无\(title)",
                message: "这里还没有公开内容",
                systemImage: "person.2",
                actionTitle: nil,
                action: nil
            )
            .listRowSeparator(.hidden)
        default:
            if case let .failed(error) = page.initialLoad {
                InlinePersonFailure(
                    message: error.message,
                    retryTitle: "重新加载当前列表",
                    retry: store.retryInitialPage
                )
            }
            ForEach(page.items) { item in
                PersonPageRow(item: item) { store.open(item) }
                    .id(item.id)
                    .onAppear { store.loadNextPageIfNeeded(after: item.id) }
            }
            pageFooter(page)
        }
    }

    @ViewBuilder
    private func pageFooter(_ page: PersonPageState) -> some View {
        switch page.nextPage {
        case .loading:
            HStack { Spacer(); ProgressView("正在加载更多"); Spacer() }
                .font(.caption)
                .listRowSeparator(.hidden)
        case let .failed(error):
            InlinePersonFailure(
                message: error.message,
                retryTitle: "重新加载更多内容",
                retry: store.retryNextPage
            )
            .listRowSeparator(.hidden)
        case .idle where page.isEnd && !page.items.isEmpty:
            Text("已经到底了")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        default:
            EmptyView()
        }
    }
}

private struct PersonScrollViewAccessor: UIViewRepresentable {
    let resolve: (UIScrollView?) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.resolve = resolve
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.resolve = resolve
        uiView.findScrollView()
    }

    final class ProbeView: UIView {
        var resolve: ((UIScrollView?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            findScrollView()
        }

        func findScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var candidate = superview
                while let view = candidate {
                    if let scrollView = view as? UIScrollView {
                        resolve?(scrollView)
                        return
                    }
                    candidate = view.superview
                }
                resolve?(nil)
            }
        }
    }
}

private struct PersonProfilePlaceholder: View {
    let displayName: String

    var body: some View {
        HStack(spacing: 16) {
            Circle().fill(Color.secondary.opacity(0.2)).frame(width: 80, height: 80)
            VStack(alignment: .leading, spacing: 8) {
                Text(displayName.isEmpty ? "用户姓名" : displayName).font(.title2)
                Text("用户简介将在这里显示").font(.body)
                Text("回答  文章  粉丝  关注").font(.caption)
            }
        }
        .padding(.vertical, 12)
    }
}

private struct PersonRowPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("内容标题占位").font(.headline)
            Text("内容摘要将在加载后显示，并保持与真实列表相同的布局高度。").font(.subheadline)
            Text("内容信息").font(.caption)
        }
        .padding(.vertical, 6)
    }
}

private struct PersonUnavailableContent: View {
    let title: String
    let message: String
    let systemImage: String
    let actionTitle: String?
    let action: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if #available(iOS 17, *) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(message)
            } actions: {
                if let actionTitle, let action { Button(actionTitle, action: action) }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.bordered) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }
}

private enum PersonSheetDestination: Identifiable {
    case avatar(URL, String)
    case badges([PersonOfficialBadge])

    var id: String {
        switch self {
        case let .avatar(url, _): return "avatar:\(url.absoluteString)"
        case .badges: return "badges"
        }
    }
}

private struct PersonSheetView: View {
    let destination: PersonSheetDestination

    var body: some View {
        switch destination {
        case let .avatar(url, name): PersonAvatarPreview(url: url, name: name)
        case let .badges(badges): PersonBadgeSheet(badges: badges)
        }
    }
}

private struct PersonAvatarPreview: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let name: String
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFit().scaleEffect(scale)
                            .gesture(MagnificationGesture().onChanged { scale = max(1, min(5, $0)) })
                    case .failure:
                        PersonUnavailableContent(title: "头像加载失败", message: "请检查网络后重新打开", systemImage: "photo", actionTitle: nil, action: nil)
                    case .empty: ProgressView().tint(.white)
                    @unknown default: EmptyView()
                    }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if #available(iOS 16, *) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    } else {
                        PersonLegacyShareButton(url: url)
                    }
                }
            }
        }
    }
}

private struct PersonBadgeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let badges: [PersonOfficialBadge]

    var body: some View {
        NavigationView {
            List(badges) { badge in
                VStack(alignment: .leading, spacing: 6) {
                    Text(badge.title).font(.headline)
                    Text(badge.description).font(.body).foregroundStyle(.secondary)
                    if let url = badge.destinationURL {
                        Link("查看认证详情", destination: url)
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("认证信息")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

private struct PersonLegacyShareButton: View {
    let url: URL
    @State private var isPresenting = false

    var body: some View {
        Button { isPresenting = true } label: { Image(systemName: "square.and.arrow.up") }
            .sheet(isPresented: $isPresenting) { ActivityViewController(items: [url]) }
    }
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
