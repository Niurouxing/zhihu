import Foundation
import SwiftUI

enum NativeNotificationCategory: String, CaseIterable, Identifiable {
    case comments = "comment"
    case likes = "like"
    case favorites = "favlist_me"
    case follows = "follow"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comments: return "评论"
        case .likes: return "赞同"
        case .favorites: return "收藏"
        case .follows: return "关注"
        }
    }

    var overviewTitle: String {
        switch self {
        case .comments: return "评论转发@"
        case .likes: return "赞同喜欢"
        case .favorites: return "收藏了我"
        case .follows: return "关注订阅"
        }
    }

    var readAllURL: URL {
        URL(string: "https://api.zhihu.com/notifications/v3/timeline/entry/\(rawValue)/actions/readall")!
    }
}

enum NativeNotificationType: String, CaseIterable, Identifiable {
    case likeAnswer = "LIKE_ANSWER"
    case likeComment = "LIKE_COMMENT"
    case replyComment = "REPLY_COMMENT"
    case inviteAnswer = "INVITE_ANSWER"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .likeAnswer: return "喜欢了你的回答"
        case .likeComment: return "喜欢了你的评论"
        case .replyComment: return "回复了你的评论"
        case .inviteAnswer: return "邀请你回答问题"
        }
    }

    var defaultDisplayInApp: Bool { self != .inviteAnswer }

    func matches(_ verb: String) -> Bool {
        let expression: String
        switch self {
        case .likeAnswer: expression = "^喜欢了你的回答$"
        case .likeComment: expression = "^喜欢了.*你的评论$"
        case .replyComment: expression = "^回复了.*你的评论$"
        case .inviteAnswer: expression = "^\\s?(邀请你回答问题|的提问等你来答|邀请你回答)$"
        }
        return verb.range(of: expression, options: .regularExpression) != nil
    }
}

@MainActor
final class NativeNotificationPreferences: ObservableObject {
    enum Key {
        static let autoRead = "auto_mark_notifications_read"
        static let unreadBadge = "show_unread_badge"
        static func display(_ type: NativeNotificationType) -> String { "display_in_app_\(type.rawValue)" }
    }

    @Published private(set) var autoMarkAsRead: Bool
    @Published private(set) var showsUnreadBadge: Bool
    @Published private(set) var displayInApp: [NativeNotificationType: Bool]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoMarkAsRead = defaults.object(forKey: Key.autoRead) == nil ? false : defaults.bool(forKey: Key.autoRead)
        showsUnreadBadge = defaults.object(forKey: Key.unreadBadge) == nil ? true : defaults.bool(forKey: Key.unreadBadge)
        displayInApp = Dictionary(uniqueKeysWithValues: NativeNotificationType.allCases.map { type in
            let key = Key.display(type)
            return (type, defaults.object(forKey: key) == nil ? type.defaultDisplayInApp : defaults.bool(forKey: key))
        })
    }

    func setAutoMarkAsRead(_ enabled: Bool) {
        autoMarkAsRead = enabled
        defaults.set(enabled, forKey: Key.autoRead)
    }

    func setShowsUnreadBadge(_ enabled: Bool) {
        showsUnreadBadge = enabled
        defaults.set(enabled, forKey: Key.unreadBadge)
    }

    func setDisplayInApp(_ enabled: Bool, for type: NativeNotificationType) {
        displayInApp[type] = enabled
        defaults.set(enabled, forKey: Key.display(type))
    }

    func shouldDisplay(verb: String) -> Bool {
        guard let type = NativeNotificationType.allCases.first(where: { $0.matches(verb) }) else {
            return true
        }
        return displayInApp[type] ?? type.defaultDisplayInApp
    }
}

struct NativeNotificationItem: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let body: String
    let created: Int64
    let createdText: String
    let isRead: Bool
    let authorName: String?
    let avatarURL: URL?
    let destination: NativeContentDestination?
}

struct NativeNotificationRepository {
    var fetchPage: (_ category: NativeNotificationCategory, _ next: URL?) async throws -> NativePage<NativeNotificationItem>
    var fetchUnreadCounts: () async throws -> [NativeNotificationCategory: Int]
    var markCategoryAsRead: (_ category: NativeNotificationCategory) async throws -> Void

    static func live(client: ZhihuAPIClient) -> NativeNotificationRepository {
        let decoder = JSONDecoder()
        let mobileHeaders = [
            "User-Agent": "com.zhihu.android/Futureve/10.61.0 Mozilla/5.0 (Linux; Android 12; sdk_gphone64_arm64 Build/SE1A.220630.001.A1; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/57.0.1000.10 Mobile Safari/537.36",
            "x-api-version": "3.1.8",
            "x-app-version": "10.61.0",
            "x-app-za": "OS=Android&Release=12&Model=sdk_gphone64_arm64&VersionName=10.61.0&VersionCode=26107&Product=com.zhihu.android&Width=1440&Height=2952&Installer=%E7%81%B0%E5%BA%A6&DeviceType=AndroidPhone&Brand=google",
        ]
        return NativeNotificationRepository(
            fetchPage: { category, next in
                let initial = URL(string: "https://api.zhihu.com/notifications/v3/timeline/entry/\(category.rawValue)?limit=20")!
                let url = try ZhihuAPIURLPolicy.validatedPagingURL(next) ?? initial
                let data = try await client.data(
                    for: url,
                    additionalHeaders: mobileHeaders,
                    authentication: .accountRequired
                )
                let payload = try decoder.decode(RawNotificationPage.self, from: data)
                return try NativePage(
                    items: payload.data.compactMap(\.value).filter { $0.type != "empty" }.map(\.item),
                    paging: NativePaging(next: ZhihuAPIURLPolicy.validatedPagingURL(payload.paging?.nextURL), isEnd: payload.paging?.isEnd ?? true)
                )
            },
            fetchUnreadCounts: {
                let url = URL(string: "https://api.zhihu.com/notifications/v3/message/v3?limit=20")!
                let data = try await client.data(
                    for: url,
                    additionalHeaders: mobileHeaders,
                    authentication: .accountRequired
                )
                let overview = try decoder.decode(RawNotificationOverview.self, from: data)
                return Dictionary(uniqueKeysWithValues: NativeNotificationCategory.allCases.map { category in
                    (category, (overview.head ?? []).first(where: { $0.detailTitle == category.overviewTitle })?.unreadCount ?? 0)
                })
            },
            markCategoryAsRead: { category in
                _ = try await client.data(
                    for: category.readAllURL,
                    method: "POST",
                    additionalHeaders: mobileHeaders,
                    authentication: .accountRequired
                )
            }
        )
    }
}

@MainActor
final class NativeNotificationStore: ObservableObject {
    @Published private(set) var selectedCategory: NativeNotificationCategory = .comments
    @Published private(set) var items: [NativeNotificationItem] = []
    @Published private(set) var unreadCounts = Dictionary(
        uniqueKeysWithValues: NativeNotificationCategory.allCases.map { ($0, 0) }
    )
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let repository: NativeNotificationRepository
    private let preferences: NativeNotificationPreferences
    private var pages: [NativeNotificationCategory: [NativeNotificationItem]] = [:]
    private var next: [NativeNotificationCategory: URL] = [:]
    private var ended: Set<NativeNotificationCategory> = []
    private var revision = UUID()

    init(repository: NativeNotificationRepository, preferences: NativeNotificationPreferences) {
        self.repository = repository
        self.preferences = preferences
    }

    var unreadCount: Int { unreadCounts.values.reduce(0, +) }
    var selectedCategoryUnreadCount: Int { unreadCounts[selectedCategory, default: 0] }

    func accountDidChange() {
        revision = UUID()
        pages.removeAll()
        next.removeAll()
        ended.removeAll()
        items = []
        unreadCounts = Dictionary(
            uniqueKeysWithValues: NativeNotificationCategory.allCases.map { ($0, 0) }
        )
        isLoading = false
        errorMessage = nil
    }

    func select(_ category: NativeNotificationCategory) async {
        guard selectedCategory != category else { return }
        revision = UUID()
        isLoading = false
        selectedCategory = category
        items = visibleItems(for: category)
        if items.isEmpty, !ended.contains(category) {
            await loadMore()
        } else if preferences.autoMarkAsRead {
            await markCategoryAsReadReportingError(category)
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        let category = selectedCategory
        pages[category] = []
        next[category] = nil
        ended.remove(category)
        items = []
        await loadMore()
    }

    func refreshUnreadCounts() async {
        do {
            unreadCounts = try await repository.fetchUnreadCounts()
        } catch is CancellationError {
            return
        } catch {
            if items.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    func loadMore() async {
        let category = selectedCategory
        guard !isLoading, !ended.contains(category) else { return }
        isLoading = true
        errorMessage = nil
        let current = UUID()
        revision = current
        defer { if revision == current { isLoading = false } }
        do {
            async let pageRequest = repository.fetchPage(category, next[category])
            async let countsRequest = repository.fetchUnreadCounts()
            let (page, counts) = try await (pageRequest, countsRequest)
            guard revision == current, selectedCategory == category else { return }
            let cached = pages[category] ?? []
            let existing = Set(cached.map(\.id))
            pages[category] = (cached + page.items.filter { !existing.contains($0.id) }).sorted { $0.created > $1.created }
            if let nextURL = page.paging.next { next[category] = nextURL } else { next.removeValue(forKey: category) }
            if page.paging.isEnd { ended.insert(category) }
            unreadCounts = counts
            items = visibleItems(for: category)
            if preferences.autoMarkAsRead {
                try await markCategoryAsRead(category)
            }
        } catch is CancellationError {
            return
        } catch {
            guard revision == current else { return }
            errorMessage = error.localizedDescription
        }
    }

    func markCategoryAsRead(_ category: NativeNotificationCategory) async throws {
        try await repository.markCategoryAsRead(category)
        unreadCounts[category] = 0
        pages[category] = (pages[category] ?? []).map {
            NativeNotificationItem(
                id: $0.id,
                title: $0.title,
                subtitle: $0.subtitle,
                body: $0.body,
                created: $0.created,
                createdText: $0.createdText,
                isRead: true,
                authorName: $0.authorName,
                avatarURL: $0.avatarURL,
                destination: $0.destination
            )
        }
        if selectedCategory == category {
            items = visibleItems(for: category)
        }
    }

    func markCurrentCategoryAsReadFromUser() async {
        await markCategoryAsReadReportingError(selectedCategory)
    }

    private func markCategoryAsReadReportingError(_ category: NativeNotificationCategory) async {
        do {
            try await markCategoryAsRead(category)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func preferencesChanged() {
        items = visibleItems(for: selectedCategory)
    }

    private func visibleItems(for category: NativeNotificationCategory) -> [NativeNotificationItem] {
        (pages[category] ?? []).filter { item in
            preferences.shouldDisplay(verb: [item.title, item.subtitle, item.body].first(where: { !$0.isEmpty }) ?? "")
        }
    }
}

@available(iOS 16.0, *)
struct NativeNotificationsView: View {
    @ObservedObject var store: NativeNotificationStore
    @ObservedObject var preferences: NativeNotificationPreferences
    let onOpenContent: (NativeContentDestination) -> Void

    var body: some View {
        List {
            Section {
                Picker("通知类型", selection: categoryBinding) {
                    ForEach(NativeNotificationCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.segmented)
            }
            if let error = store.errorMessage, !store.items.isEmpty {
                NativeInlineRetry(message: error) { Task { await store.loadMore() } }
            }
            ForEach(store.items) { item in
                NativeNotificationRow(item: item, onOpenContent: onOpenContent)
            }
            if store.isLoading, !store.items.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if !store.items.isEmpty {
                Color.clear.frame(height: 1).task { await store.loadMore() }
            }
        }
        .listStyle(.plain)
        .navigationTitle("通知")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await store.markCurrentCategoryAsReadFromUser() }
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .disabled(store.selectedCategoryUnreadCount == 0)
                .accessibilityLabel("标记当前分类为已读")
                NavigationLink(value: NativeShellRoute.notificationSettings) {
                    Image(systemName: "gearshape")
                }
            }
        }
        .refreshable { await store.refresh() }
        .overlay { initialState }
        .task {
            if store.items.isEmpty, !store.isLoading { await store.refresh() }
        }
        .onChange(of: preferences.displayInApp) { _ in
            store.preferencesChanged()
        }
    }

    private var categoryBinding: Binding<NativeNotificationCategory> {
        Binding(
            get: { store.selectedCategory },
            set: { category in Task { await store.select(category) } }
        )
    }

    @ViewBuilder private var initialState: some View {
        if store.isLoading, store.items.isEmpty {
            ProgressView("正在加载通知")
        } else if let error = store.errorMessage, store.items.isEmpty {
            NativeUnavailableState(title: "无法加载通知", message: error, actionTitle: "重试") {
                Task { await store.refresh() }
            }
        } else if store.items.isEmpty {
            NativeUnavailableState(title: "暂无通知", message: "当前分类没有可显示的通知")
        }
    }
}

private struct NativeNotificationRow: View {
    let item: NativeNotificationItem
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
        row
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: item.avatarURL) { phase in
                    if case let .success(image) = phase { image.resizable().scaledToFill() }
                    else { Image(systemName: "bell.circle.fill").resizable().foregroundStyle(.secondary) }
                }
                .frame(width: 42, height: 42).clipShape(Circle())
                if !item.isRead {
                    Circle().fill(.red).frame(width: 9, height: 9).overlay(Circle().stroke(.background, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title.isEmpty ? item.subtitle : item.title).font(.headline).foregroundStyle(.primary)
                if !item.body.isEmpty {
                    Text(item.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
                Text(item.createdText).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct RawNotificationPage: Decodable {
    let data: [NativeLossyDecoded<RawNotification>]
    let paging: NotificationPaging?
}

private struct NotificationPaging: Decodable {
    let isEnd: Bool
    let next: String?
    var nextURL: URL? { next.flatMap(URL.init(string:)) }

    private enum CodingKeys: String, CodingKey {
        case isEnd = "is_end"
        case next
    }
}

private struct RawNotificationOverview: Decodable { let head: [RawNotificationHeadEntry]? }
private struct RawNotificationHeadEntry: Decodable {
    let detailTitle: String
    let unreadCount: Int
    private enum CodingKeys: String, CodingKey {
        case detailTitle = "detail_title"
        case unreadCount = "unread_count"
    }
}

private struct RawNotification: Decodable {
    let id: String
    let uniqueID: String
    let type: String
    let cardType: String
    let detailTitle: String
    let isRead: Bool
    let created: Int64
    let createdString: String
    let head: RawNotificationHead?
    let content: RawNotificationContent?
    let targetSource: RawNotificationTargetSource?
    let target: RawNotificationTarget?

    private enum CodingKeys: String, CodingKey {
        case id, type, head, content, target
        case uniqueID = "unique_id"
        case cardType = "card_type"
        case detailTitle = "detail_title"
        case isRead = "is_read"
        case created
        case createdString = "created_str"
        case targetSource = "target_source"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeFlexibleString(forKey: .id)) ?? ""
        uniqueID = try container.decodeIfPresent(String.self, forKey: .uniqueID) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        cardType = try container.decodeIfPresent(String.self, forKey: .cardType) ?? ""
        detailTitle = try container.decodeIfPresent(String.self, forKey: .detailTitle) ?? ""
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? true
        created = try container.decodeIfPresent(Int64.self, forKey: .created) ?? 0
        createdString = try container.decodeIfPresent(String.self, forKey: .createdString) ?? ""
        head = try container.decodeIfPresent(RawNotificationHead.self, forKey: .head)
        content = try container.decodeIfPresent(RawNotificationContent.self, forKey: .content)
        targetSource = try container.decodeIfPresent(RawNotificationTargetSource.self, forKey: .targetSource)
        target = try container.decodeIfPresent(RawNotificationTarget.self, forKey: .target)
    }

    var item: NativeNotificationItem {
        let stableID = !uniqueID.isEmpty ? uniqueID : (!id.isEmpty ? id : "\(created)-\(cardType)-\(detailTitle)")
        let title = content?.title ?? detailTitle
        let subtitle = content?.subTitle ?? ""
        let body = [content?.text, content?.subText, content?.abstractText, targetSource?.text, targetSource?.fullText]
            .compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
        let rawDestination = [content?.targetLink, head?.targetLink, targetSource?.targetLink, target?.url]
            .compactMap { $0 }.first(where: { !$0.isEmpty })
        return NativeNotificationItem(
            id: stableID,
            title: title,
            subtitle: subtitle,
            body: body,
            created: created,
            createdText: createdString,
            isRead: isRead,
            authorName: head?.author?.name ?? target?.name,
            avatarURL: [head?.author?.avatarURL, head?.avatarURL, target?.avatarURL]
                .compactMap { $0 }.first(where: { !$0.isEmpty }).flatMap(URL.init(string:)),
            destination: NativeContentDestinationResolver.resolve(rawDestination)
        )
    }
}

private struct RawNotificationHead: Decodable {
    let author: RawNotificationAuthor?
    let avatarURL: String?
    let targetLink: String?
    private enum CodingKeys: String, CodingKey {
        case author
        case avatarURL = "avatar_url"
        case targetLink = "target_link"
    }
}

private struct RawNotificationAuthor: Decodable {
    let name: String?
    let avatarURL: String?
    private enum CodingKeys: String, CodingKey { case name; case avatarURL = "avatar_url" }
}

private struct RawNotificationContent: Decodable {
    let title: String?
    let subTitle: String?
    let text: String?
    let subText: String?
    let abstractText: String?
    let targetLink: String?
    private enum CodingKeys: String, CodingKey {
        case title, text
        case subTitle = "sub_title"
        case subText = "sub_text"
        case abstractText = "abstract_text"
        case targetLink = "target_link"
    }
}

private struct RawNotificationTargetSource: Decodable {
    let text: String?
    let fullText: String?
    let targetLink: String?
    private enum CodingKeys: String, CodingKey {
        case text
        case fullText = "full_text"
        case targetLink = "target_link"
    }
}

private struct RawNotificationTarget: Decodable {
    let name: String?
    let avatarURL: String?
    let url: String?
    private enum CodingKeys: String, CodingKey { case name, url; case avatarURL = "avatar_url" }
}
