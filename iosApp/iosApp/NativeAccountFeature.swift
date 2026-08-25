import Foundation
import SwiftUI
import UIKit

struct NativeAccountIdentity: Equatable, Hashable {
    let id: String
    let name: String
    let urlToken: String?
    let userType: String
    let avatarURL: URL?

    var collectionToken: String? {
        let token = urlToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !token.isEmpty { return token }
        let identifier = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? nil : identifier
    }
}

struct NativeStoredAccount: Equatable {
    let isLoggedIn: Bool
    let username: String
    let identity: NativeAccountIdentity?
}

struct NativeAccountRepository {
    var load: () throws -> NativeStoredAccount
    var refreshProfile: () async throws -> NativeStoredAccount
    var signOut: () throws -> Void
    var listAccounts: () throws -> [NativeSavedAccountSummary]
    var currentAccountID: () throws -> String?
    var switchAccount: (_ accountID: String) throws -> NativeStoredAccount
    var deleteAccount: (_ accountID: String) throws -> Void

    init(
        load: @escaping () throws -> NativeStoredAccount,
        refreshProfile: @escaping () async throws -> NativeStoredAccount,
        signOut: @escaping () throws -> Void,
        listAccounts: @escaping () throws -> [NativeSavedAccountSummary] = { [] },
        currentAccountID: @escaping () throws -> String? = { nil },
        switchAccount: @escaping (_ accountID: String) throws -> NativeStoredAccount = { _ in
            throw MultipleAccountStoreError.accountNotFound
        },
        deleteAccount: @escaping (_ accountID: String) throws -> Void = { _ in
            throw MultipleAccountStoreError.accountNotFound
        }
    ) {
        self.load = load
        self.refreshProfile = refreshProfile
        self.signOut = signOut
        self.listAccounts = listAccounts
        self.currentAccountID = currentAccountID
        self.switchAccount = switchAccount
        self.deleteAccount = deleteAccount
    }

    static func live(accountStore: AccountJSONStore, client: ZhihuAPIClient) -> NativeAccountRepository {
        let multipleAccountStore = accountStore as? MultipleAccountJSONStore
        return NativeAccountRepository(
            load: {
                try NativeAccountCodec.decode(accountStore.load())
            },
            refreshProfile: {
                let url = URL(string: "https://www.zhihu.com/api/v4/me")!
                let data = try await client.data(for: url, authentication: .accountRequired)
                let profile = try NativeAccountCodec.decodeProfileResponse(data)
                try accountStore.update { existingJSON in
                    try NativeAccountCodec.merging(profile: profile, into: existingJSON)
                }
                return try NativeAccountCodec.decode(accountStore.load())
            },
            signOut: {
                if let multipleAccountStore {
                    try multipleAccountStore.clearCurrentAccount()
                } else {
                    try accountStore.clear()
                }
            },
            listAccounts: {
                if let multipleAccountStore {
                    return try multipleAccountStore.listAccounts()
                }
                let current = try NativeAccountCodec.decode(accountStore.load())
                guard current.isLoggedIn, let identity = current.identity else { return [] }
                return [NativeSavedAccountSummary(
                    id: identity.id,
                    name: identity.name,
                    urlToken: identity.urlToken,
                    avatarURL: identity.avatarURL
                )]
            },
            currentAccountID: {
                if let multipleAccountStore {
                    return try multipleAccountStore.currentAccountID()
                }
                return try NativeAccountCodec.decode(accountStore.load()).identity?.id
            },
            switchAccount: { accountID in
                guard let multipleAccountStore else {
                    throw MultipleAccountStoreError.accountNotFound
                }
                try multipleAccountStore.switchAccount(to: accountID)
                return try NativeAccountCodec.decode(accountStore.load())
            },
            deleteAccount: { accountID in
                guard let multipleAccountStore else {
                    throw MultipleAccountStoreError.accountNotFound
                }
                try multipleAccountStore.deleteAccount(accountID)
            }
        )
    }
}

enum NativeAccountCodec {
    enum CodecError: LocalizedError {
        case malformedAccount
        case malformedProfile

        var errorDescription: String? {
            switch self {
            case .malformedAccount: return "账号信息无法读取，请重新登录"
            case .malformedProfile: return "服务器返回的账号资料无法识别"
            }
        }
    }

    static func decode(_ accountJSON: String?) throws -> NativeStoredAccount {
        guard let accountJSON, !accountJSON.isEmpty else {
            return NativeStoredAccount(isLoggedIn: false, username: "", identity: nil)
        }
        guard let data = accountJSON.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CodecError.malformedAccount }
        let login = root["login"] as? Bool ?? false
        let username = root["username"] as? String ?? ""
        let profile = root["profile"] as? [String: Any]
        let identity = profile.flatMap { profile -> NativeAccountIdentity? in
            let id = profile["id"] as? String ?? ""
            let name = profile["name"] as? String ?? username
            let urlToken = profile["urlToken"] as? String
            let userType = profile["userType"] as? String ?? ""
            let avatar = (profile["avatarUrl"] as? String).flatMap(URL.init(string:))
            guard !id.isEmpty || !(urlToken ?? "").isEmpty || !name.isEmpty else { return nil }
            return NativeAccountIdentity(
                id: id,
                name: name,
                urlToken: urlToken,
                userType: userType,
                avatarURL: avatar
            )
        }
        return NativeStoredAccount(isLoggedIn: login, username: username, identity: identity)
    }

    static func decodeProfileResponse(_ data: Data) throws -> NativeAccountIdentity {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodecError.malformedProfile
        }
        let id = root["id"] as? String ?? ""
        let name = root["name"] as? String ?? ""
        let urlToken = root["url_token"] as? String ?? root["urlToken"] as? String
        let userType = root["user_type"] as? String ?? root["userType"] as? String ?? ""
        let avatar = (root["avatar_url"] as? String ?? root["avatarUrl"] as? String).flatMap(URL.init(string:))
        guard !id.isEmpty, !name.isEmpty else { throw CodecError.malformedProfile }
        return NativeAccountIdentity(
            id: id,
            name: name,
            urlToken: urlToken,
            userType: userType,
            avatarURL: avatar
        )
    }

    static func merging(profile: NativeAccountIdentity, into accountJSON: String?) throws -> String {
        guard let accountJSON,
              let data = accountJSON.data(using: .utf8),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CodecError.malformedAccount }
        root["login"] = true
        root["username"] = profile.name
        var storedProfile: [String: Any] = [
            "id": profile.id,
            "name": profile.name,
            "userType": profile.userType,
        ]
        storedProfile["urlToken"] = profile.urlToken ?? NSNull()
        storedProfile["avatarUrl"] = profile.avatarURL?.absoluteString ?? NSNull()
        root["profile"] = storedProfile
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let result = String(data: updated, encoding: .utf8) else {
            throw CodecError.malformedAccount
        }
        return result
    }
}

@MainActor
final class NativeAccountStore: ObservableObject {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(NativeAccountIdentity)
        case failed(message: String, retainedIdentity: NativeAccountIdentity?)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSigningOut = false
    @Published private(set) var accounts: [NativeSavedAccountSummary] = []
    @Published private(set) var currentAccountID: String?
    @Published private(set) var switchingToAccountID: String?
    @Published private(set) var deletingAccountID: String?

    private let repository: NativeAccountRepository
    init(repository: NativeAccountRepository) {
        self.repository = repository
    }

    var identity: NativeAccountIdentity? {
        switch state {
        case let .signedIn(identity): return identity
        case let .failed(_, retainedIdentity): return retainedIdentity
        case .loading, .signedOut: return nil
        }
    }

    var isSignedIn: Bool { identity != nil }

    func reloadFromKeychain() {
        do {
            apply(try repository.load())
            try reloadAccountList()
        } catch {
            state = .failed(message: error.localizedDescription, retainedIdentity: identity)
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            apply(try await repository.refreshProfile())
            try reloadAccountList()
        } catch is CancellationError {
            return
        } catch {
            state = .failed(message: error.localizedDescription, retainedIdentity: identity)
        }
    }

    func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            try repository.signOut()
            state = .signedOut
            try reloadAccountList()
        } catch {
            state = .failed(message: error.localizedDescription, retainedIdentity: identity)
        }
    }

    func switchAccount(to accountID: String) {
        guard switchingToAccountID == nil, deletingAccountID == nil, currentAccountID != accountID else { return }
        switchingToAccountID = accountID
        defer { switchingToAccountID = nil }
        do {
            apply(try repository.switchAccount(accountID))
            try reloadAccountList()
        } catch {
            state = .failed(message: error.localizedDescription, retainedIdentity: identity)
        }
    }

    func deleteAccount(_ accountID: String) {
        guard switchingToAccountID == nil,
              deletingAccountID == nil,
              currentAccountID != accountID
        else { return }
        deletingAccountID = accountID
        defer { deletingAccountID = nil }
        do {
            try repository.deleteAccount(accountID)
            try reloadAccountList()
        } catch {
            state = .failed(message: error.localizedDescription, retainedIdentity: identity)
        }
    }

    private func apply(_ account: NativeStoredAccount) {
        if account.isLoggedIn, let identity = account.identity {
            state = .signedIn(identity)
        } else {
            state = .signedOut
        }
    }

    private func reloadAccountList() throws {
        accounts = try repository.listAccounts()
        currentAccountID = try repository.currentAccountID()
    }
}

struct NativeAccountActions {
    let openLogin: () -> Void
    let openQrAuthorization: () -> Void
    let openProfile: (NativeAccountIdentity) -> Void
}

@available(iOS 16.0, *)
struct NativeAccountView: View {
    @ObservedObject var store: NativeAccountStore
    let actions: NativeAccountActions

    @State private var confirmsSignOut = false

    var body: some View {
        List {
            accountSection
            failureSection
            destinationsSection
            accountManagementSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            if store.isSignedIn { await store.refresh() }
        }
        .task {
            if case .loading = store.state { store.reloadFromKeychain() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            store.reloadFromKeychain()
        }
        .accessibilityIdentifier("native_account_center")
        .alert("退出登录", isPresented: $confirmsSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive, action: store.signOut)
        } message: {
            Text("退出后，当前账号保存的知乎登录状态将从本机移除，其他已保存账号不受影响。")
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            switch store.state {
            case .loading:
                NativeAccountHeroCard(identity: nil, isLoading: true, isRefreshing: false) {}
            case let .signedIn(identity), let .failed(_, identity?):
                NativeAccountHeroCard(identity: identity, isLoading: false, isRefreshing: store.isRefreshing) {
                    actions.openProfile(identity)
                }
            case .signedOut, .failed(_, nil):
                NativeAccountHeroCard(identity: nil, isLoading: false, isRefreshing: false) {
                    actions.openLogin()
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var failureSection: some View {
        if case let .failed(message, _) = store.state {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("重新读取", action: store.reloadFromKeychain)
                        .font(.footnote.weight(.semibold))
                }
            }
        }
    }

    private var destinationsSection: some View {
        Section("内容与工具") {
            if let identity = store.identity {
                if let token = identity.collectionToken {
                    NativeAccountDestinationRow(
                        title: "收藏夹",
                        subtitle: "保存的回答与文章",
                        systemImage: "bookmark.fill",
                        tint: .blue,
                        route: .collections(userToken: token)
                    )
                }

                NativeAccountDestinationRow(
                    title: "浏览历史",
                    subtitle: "找回最近看过的内容",
                    systemImage: "clock.arrow.circlepath",
                    tint: .orange,
                    route: .history
                )

                NativeAccountDestinationRow(
                    title: "通知",
                    subtitle: "互动与账号消息",
                    systemImage: "bell.fill",
                    tint: .purple,
                    route: .notifications
                )
            }

            NativeAccountDestinationRow(
                title: "设置",
                subtitle: "外观、阅读与账号偏好",
                systemImage: "gearshape.fill",
                tint: .gray,
                route: .settings
            )
        }
    }

    @ViewBuilder
    private var accountManagementSection: some View {
        if store.isSignedIn || !store.accounts.isEmpty {
            Section {
                ForEach(managedAccounts) { account in
                    Button {
                        store.switchAccount(to: account.id)
                    } label: {
                        HStack(spacing: 12) {
                            NativeSavedAccountAvatar(account: account, diameter: 40)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.name)
                                    .foregroundStyle(.primary)
                                Text(accountSubtitle(account))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if store.switchingToAccountID == account.id {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.switchingToAccountID != nil || store.deletingAccountID != nil)
                    .accessibilityLabel("切换到账号\(account.name)")
                    .swipeActions {
                        Button(role: .destructive) {
                            store.deleteAccount(account.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }

                Button(action: actions.openLogin) {
                    Label("添加账号", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(store.switchingToAccountID != nil || store.deletingAccountID != nil)

                if store.isSignedIn {
                    Button(action: actions.openQrAuthorization) {
                        Label("扫码授权网页账号", systemImage: "qrcode.viewfinder")
                    }

                    Button(role: .destructive) {
                        confirmsSignOut = true
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(store.isSigningOut)
                }
            } header: {
                Text("账号与安全")
            } footer: {
                Text("账号登录状态仅保存在本机 Keychain 中；切换账号不会覆盖其他已保存账号。")
            }
        }
    }

    private var managedAccounts: [NativeSavedAccountSummary] {
        guard store.isSignedIn else { return store.accounts }
        return store.accounts.filter { $0.id != store.currentAccountID }
    }

    private func accountSubtitle(_ account: NativeSavedAccountSummary) -> String {
        guard let token = account.urlToken, !token.isEmpty else { return "已验证账号" }
        return "@\(token)"
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("知乎++", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            NavigationLink(value: NativeShellRoute.systemAndUpdate) {
                Label("系统与更新", systemImage: "info.circle")
            }
        } header: {
            Text("关于")
        } footer: {
            Text("本软件仅供学习交流使用，应用内内容由知乎网站提供。")
        }
    }
}

@available(iOS 16.0, *)
private struct NativeAccountHeroCard: View {
    let identity: NativeAccountIdentity?
    let isLoading: Bool
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                avatar

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if isRefreshing {
                    ProgressView()
                } else if !isLoading {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityIdentifier("native_account_profile_card")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(identity == nil ? "打开知乎登录" : "查看个人主页")
    }

    @ViewBuilder
    private var avatar: some View {
        if isLoading {
            ProgressView()
                .frame(width: 64, height: 64)
                .background(Color.secondary.opacity(0.1), in: Circle())
        } else if let identity {
            NativeAccountAvatar(identity: identity, diameter: 64)
        } else {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 36, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
                .frame(width: 64, height: 64)
                .background(Color.blue.opacity(0.1), in: Circle())
        }
    }

    private var title: String {
        if isLoading { return "正在读取账号" }
        return identity?.name ?? "登录知乎"
    }

    private var subtitle: String {
        if isLoading { return "请稍候" }
        guard let identity else { return "登录后查看收藏、历史与通知" }
        guard let token = identity.urlToken, !token.isEmpty else { return "查看个人主页" }
        return "@\(token)"
    }

    private var accessibilityLabel: String {
        if isLoading { return "正在读取账号" }
        return identity.map { "\($0.name)，查看个人主页" } ?? "登录知乎"
    }
}

@available(iOS 16.0, *)
private struct NativeAccountDestinationRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let route: NativeShellRoute

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 3)
        }
    }
}

struct NativeAccountAvatar: View {
    let identity: NativeAccountIdentity?
    let diameter: CGFloat

    var body: some View {
        AsyncImage(url: identity?.avatarURL) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .accessibilityLabel(identity.map { "\($0.name)的头像" } ?? "账号")
    }
}

private struct NativeSavedAccountAvatar: View {
    let account: NativeSavedAccountSummary
    let diameter: CGFloat

    var body: some View {
        AsyncImage(url: account.avatarURL) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .accessibilityLabel("\(account.name)的头像")
    }
}
