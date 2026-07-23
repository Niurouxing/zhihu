import Foundation
import SwiftUI

enum NativeAppTab: String, CaseIterable, Identifiable, Codable {
    case home = "Home"
    case follow = "Follow"
    case hot = "HotList"
    case daily = "Daily"
    case history = "OnlineHistory"
    case collections = "MyCollections"
    case account = "Account"
    case search = "Search"

    var id: String { rawValue }

    static let primaryBottomBarTabs: [NativeAppTab] = [
        .home,
        .collections,
        .account,
    ]

    static let fixedBottomBarTabs: [NativeAppTab] = primaryBottomBarTabs + [.search]
    static let startTabCandidates = fixedBottomBarTabs

    // Kept for compatibility with the legacy preference migration helpers.
    static let bottomBarCandidates = fixedBottomBarTabs

    var title: String {
        switch self {
        case .home: return "首页"
        case .follow: return "关注"
        case .hot: return "热榜"
        case .daily: return "日报"
        case .history: return "历史"
        case .collections: return "收藏"
        case .account: return "账号"
        case .search: return "搜索"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .follow: return "person.2.fill"
        case .hot: return "flame.fill"
        case .daily: return "newspaper.fill"
        case .history: return "clock.arrow.circlepath"
        case .collections: return "bookmark.fill"
        case .account: return "person.crop.circle"
        case .search: return "magnifyingglass"
        }
    }

    var usesSearchRole: Bool { self == .search }
}

enum NativeThemeMode: String, CaseIterable, Identifiable {
    case system = "SYSTEM"
    case light = "LIGHT"
    case dark = "DARK"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum NativeFeedDensity: String, CaseIterable, Identifiable {
    case compact
    case standard
    case comfortable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "紧凑"
        case .standard: return "标准"
        case .comfortable: return "宽松"
        }
    }

    var rowVerticalPadding: CGFloat {
        switch self {
        case .compact: return 2
        case .standard: return 7
        case .comfortable: return 12
        }
    }
}

enum NativeDefaultShareAction: String, CaseIterable, Identifiable {
    case ask
    case systemShare = "share"
    case copyLink = "copy"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "每次询问"
        case .systemShare: return "系统分享"
        case .copyLink: return "复制链接"
        }
    }
}

struct NativeContentPresentationPreferences: Equatable {
    var fontSizePercent = 100
    var lineHeightPercent = 160
    var blockSpacingPercent = 100
    var feedDensity = NativeFeedDensity.standard
    var feedExcerptLines = 2
    var showsFeedThumbnails = true

    var fontScale: CGFloat { CGFloat(fontSizePercent) / 100 }

    func extraLineSpacing(for pointSize: CGFloat) -> CGFloat {
        max(0, pointSize * (CGFloat(lineHeightPercent) / 100 - 1))
    }

    func blockSpacing(base: CGFloat = 16) -> CGFloat {
        base * CGFloat(blockSpacingPercent) / 100
    }
}

private struct NativeContentPresentationPreferencesKey: EnvironmentKey {
    static let defaultValue = NativeContentPresentationPreferences()
}

extension EnvironmentValues {
    var nativeContentPresentation: NativeContentPresentationPreferences {
        get { self[NativeContentPresentationPreferencesKey.self] }
        set { self[NativeContentPresentationPreferencesKey.self] = newValue }
    }
}

struct NativeSearchPresentationPreferences: Equatable {
    var showsHotSearch = true
    var showsHistory = true
}

private struct NativeSearchPresentationPreferencesKey: EnvironmentKey {
    static let defaultValue = NativeSearchPresentationPreferences()
}

extension EnvironmentValues {
    var nativeSearchPresentation: NativeSearchPresentationPreferences {
        get { self[NativeSearchPresentationPreferencesKey.self] }
        set { self[NativeSearchPresentationPreferencesKey.self] = newValue }
    }
}

@MainActor
final class NativeShellPreferences: ObservableObject {
    private static let currentBottomTabStructureVersion = 3

    enum Key {
        static let themeMode = "themeMode"
        static let accountInHome = "duo3_home_account"
        static let selectedTabs = "bottom_bar_items"
        static let tabOrder = "bottom_bar_item_order"
        static let bottomTabStructureVersion = "nativeBottomTabStructureVersion"
        static let startTab = "startDestination"
        static let autoHideTabBar = "autoHideBottomBar"
        static let contentFontSize = "contentFontSize"
        static let contentLineHeight = "contentLineHeight"
        static let contentBlockSpacing = "contentBlockSpacing"
        static let feedDensity = "nativeFeedDensity"
        static let feedExcerptLines = "nativeFeedExcerptLines"
        static let showFeedThumbnail = "showFeedThumbnail"
        static let showSearchHotSearch = "showSearchHotSearch"
        static let showSearchHistory = "showSearchHistory"
        static let topLevelReselect = "nativeTopLevelReselect"
        static let shareActionMode = "shareActionMode"
        static let hapticsEnabled = "nativeHapticsEnabled"
        static let hapticStrength = "nativeHapticStrength"
    }

    private let defaults: UserDefaults

    @Published private(set) var themeMode: NativeThemeMode
    @Published private(set) var accountInHome: Bool
    @Published private(set) var selectedTabs: [NativeAppTab]
    @Published private(set) var startTab: NativeAppTab
    @Published private(set) var autoHideTabBar: Bool
    @Published private(set) var contentFontSizePercent: Int
    @Published private(set) var contentLineHeightPercent: Int
    @Published private(set) var contentBlockSpacingPercent: Int
    @Published private(set) var feedDensity: NativeFeedDensity
    @Published private(set) var feedExcerptLines: Int
    @Published private(set) var showsFeedThumbnails: Bool
    @Published private(set) var showsSearchHotSearch: Bool
    @Published private(set) var showsSearchHistory: Bool
    @Published private(set) var topLevelReselectEnabled: Bool
    @Published private(set) var defaultShareAction: NativeDefaultShareAction
    @Published private(set) var hapticsEnabled: Bool
    @Published private(set) var hapticStrength: NativeHapticStrength

    var contentPresentation: NativeContentPresentationPreferences {
        NativeContentPresentationPreferences(
            fontSizePercent: contentFontSizePercent,
            lineHeightPercent: contentLineHeightPercent,
            blockSpacingPercent: contentBlockSpacingPercent,
            feedDensity: feedDensity,
            feedExcerptLines: feedExcerptLines,
            showsFeedThumbnails: showsFeedThumbnails
        )
    }

    var searchPresentation: NativeSearchPresentationPreferences {
        NativeSearchPresentationPreferences(
            showsHotSearch: showsSearchHotSearch,
            showsHistory: showsSearchHistory
        )
    }

    var hapticFeedbackConfiguration: NativeHapticFeedbackConfiguration {
        NativeHapticFeedbackConfiguration(
            isEnabled: hapticsEnabled,
            strength: hapticStrength
        )
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let accountInHome = defaults.object(forKey: Key.accountInHome) == nil
            ? false
            : defaults.bool(forKey: Key.accountInHome)
        var selectedKeys = defaults.stringArray(forKey: Key.selectedTabs)
            ?? Self.defaultSelection(accountInHome: accountInHome).map(\.rawValue)
        let requiresLegacyAccountMigration = defaults.integer(forKey: Key.bottomTabStructureVersion) < 2
        if requiresLegacyAccountMigration, accountInHome {
            if selectedKeys.contains(NativeAppTab.home.rawValue) {
                selectedKeys.removeAll { $0 == NativeAppTab.account.rawValue }
            } else if !selectedKeys.contains(NativeAppTab.account.rawValue) {
                selectedKeys.append(NativeAppTab.account.rawValue)
            }
        }
        let preferredOrder = defaults.string(forKey: Key.tabOrder)
            .map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            ?? []
        let tabs = Self.normalizedTabs(
            selectedKeys: selectedKeys,
            preferredOrder: preferredOrder,
            accountInHome: accountInHome
        )

        self.accountInHome = accountInHome
        selectedTabs = tabs
        defaults.set(tabs.map(\.rawValue), forKey: Key.selectedTabs)
        defaults.set(tabs.map(\.rawValue).joined(separator: ","), forKey: Key.tabOrder)
        defaults.set(Self.currentBottomTabStructureVersion, forKey: Key.bottomTabStructureVersion)
        let rawTheme = defaults.string(forKey: Key.themeMode) ?? NativeThemeMode.system.rawValue
        themeMode = NativeThemeMode(rawValue: rawTheme) ?? .system
        let storedStart = defaults.string(forKey: Key.startTab)
        let preferredStart = storedStart.flatMap(NativeAppTab.init(rawValue:))
        let normalizedStart = preferredStart.flatMap {
            NativeAppTab.startTabCandidates.contains($0) ? $0 : nil
        }
            ?? .home
        startTab = normalizedStart
        if storedStart != nil, preferredStart != normalizedStart {
            defaults.set(normalizedStart.rawValue, forKey: Key.startTab)
        }
        autoHideTabBar = defaults.object(forKey: Key.autoHideTabBar) == nil
            ? false
            : defaults.bool(forKey: Key.autoHideTabBar)
        contentFontSizePercent = Self.clamp(defaults.object(forKey: Key.contentFontSize) == nil
            ? 100
            : defaults.integer(forKey: Key.contentFontSize), to: 80 ... 150)
        contentLineHeightPercent = Self.clamp(defaults.object(forKey: Key.contentLineHeight) == nil
            ? 160
            : defaults.integer(forKey: Key.contentLineHeight), to: 100 ... 300)
        contentBlockSpacingPercent = Self.clamp(defaults.object(forKey: Key.contentBlockSpacing) == nil
            ? 100
            : defaults.integer(forKey: Key.contentBlockSpacing), to: 0 ... 300)
        feedDensity = defaults.string(forKey: Key.feedDensity)
            .flatMap(NativeFeedDensity.init(rawValue:)) ?? .standard
        feedExcerptLines = Self.clamp(defaults.object(forKey: Key.feedExcerptLines) == nil
            ? 2
            : defaults.integer(forKey: Key.feedExcerptLines), to: 1 ... 5)
        showsFeedThumbnails = Self.bool(defaults, key: Key.showFeedThumbnail, defaultValue: true)
        showsSearchHotSearch = Self.bool(defaults, key: Key.showSearchHotSearch, defaultValue: true)
        showsSearchHistory = Self.bool(defaults, key: Key.showSearchHistory, defaultValue: true)
        topLevelReselectEnabled = Self.bool(defaults, key: Key.topLevelReselect, defaultValue: true)
        defaultShareAction = defaults.string(forKey: Key.shareActionMode)
            .flatMap(NativeDefaultShareAction.init(rawValue:)) ?? .ask
        hapticsEnabled = Self.bool(defaults, key: Key.hapticsEnabled, defaultValue: true)
        hapticStrength = defaults.string(forKey: Key.hapticStrength)
            .flatMap(NativeHapticStrength.init(rawValue:)) ?? .standard
    }

    func setThemeMode(_ mode: NativeThemeMode) {
        guard themeMode != mode else { return }
        themeMode = mode
        defaults.set(mode.rawValue, forKey: Key.themeMode)
    }

    func setAutoHideTabBar(_ enabled: Bool) {
        guard autoHideTabBar != enabled else { return }
        autoHideTabBar = enabled
        defaults.set(enabled, forKey: Key.autoHideTabBar)
    }

    func setContentFontSizePercent(_ value: Int) {
        let value = Self.clamp(value, to: 80 ... 150)
        guard contentFontSizePercent != value else { return }
        contentFontSizePercent = value
        defaults.set(value, forKey: Key.contentFontSize)
    }

    func setContentLineHeightPercent(_ value: Int) {
        let value = Self.clamp(value, to: 100 ... 300)
        guard contentLineHeightPercent != value else { return }
        contentLineHeightPercent = value
        defaults.set(value, forKey: Key.contentLineHeight)
    }

    func setContentBlockSpacingPercent(_ value: Int) {
        let value = Self.clamp(value, to: 0 ... 300)
        guard contentBlockSpacingPercent != value else { return }
        contentBlockSpacingPercent = value
        defaults.set(value, forKey: Key.contentBlockSpacing)
    }

    func setFeedDensity(_ value: NativeFeedDensity) {
        guard feedDensity != value else { return }
        feedDensity = value
        defaults.set(value.rawValue, forKey: Key.feedDensity)
    }

    func setFeedExcerptLines(_ value: Int) {
        let value = Self.clamp(value, to: 1 ... 5)
        guard feedExcerptLines != value else { return }
        feedExcerptLines = value
        defaults.set(value, forKey: Key.feedExcerptLines)
    }

    func setShowsFeedThumbnails(_ enabled: Bool) {
        guard showsFeedThumbnails != enabled else { return }
        showsFeedThumbnails = enabled
        defaults.set(enabled, forKey: Key.showFeedThumbnail)
    }

    func setShowsSearchHotSearch(_ enabled: Bool) {
        guard showsSearchHotSearch != enabled else { return }
        showsSearchHotSearch = enabled
        defaults.set(enabled, forKey: Key.showSearchHotSearch)
    }

    func setShowsSearchHistory(_ enabled: Bool) {
        guard showsSearchHistory != enabled else { return }
        showsSearchHistory = enabled
        defaults.set(enabled, forKey: Key.showSearchHistory)
    }

    func setTopLevelReselectEnabled(_ enabled: Bool) {
        guard topLevelReselectEnabled != enabled else { return }
        topLevelReselectEnabled = enabled
        defaults.set(enabled, forKey: Key.topLevelReselect)
    }

    func setDefaultShareAction(_ action: NativeDefaultShareAction) {
        guard defaultShareAction != action else { return }
        defaultShareAction = action
        defaults.set(action.rawValue, forKey: Key.shareActionMode)
    }

    func setHapticsEnabled(_ enabled: Bool) {
        guard hapticsEnabled != enabled else { return }
        hapticsEnabled = enabled
        defaults.set(enabled, forKey: Key.hapticsEnabled)
    }

    func setHapticStrength(_ strength: NativeHapticStrength) {
        guard hapticStrength != strength else { return }
        hapticStrength = strength
        defaults.set(strength.rawValue, forKey: Key.hapticStrength)
    }

    func setTabEnabled(_ tab: NativeAppTab, enabled: Bool) {
        var selection = Set(selectedTabs)
        if enabled {
            selection.insert(tab)
        } else {
            selection.remove(tab)
        }
        applyTabSelection(Array(selection), preferredOrder: selectedTabs)
    }

    func moveTabs(fromOffsets: IndexSet, toOffset: Int) {
        var next = selectedTabs
        next.move(fromOffsets: fromOffsets, toOffset: toOffset)
        selectedTabs = next
        defaults.set(next.map(\.rawValue).joined(separator: ","), forKey: Key.tabOrder)
    }

    func setStartTab(_ tab: NativeAppTab) {
        guard NativeAppTab.startTabCandidates.contains(tab), startTab != tab else { return }
        startTab = tab
        defaults.set(tab.rawValue, forKey: Key.startTab)
    }

    private func applyTabSelection(_ selection: [NativeAppTab], preferredOrder: [NativeAppTab]) {
        let normalized = Self.normalizedTabs(
            selectedKeys: selection.map(\.rawValue),
            preferredOrder: preferredOrder.map(\.rawValue),
            accountInHome: accountInHome
        )
        selectedTabs = normalized
        defaults.set(normalized.map(\.rawValue), forKey: Key.selectedTabs)
        defaults.set(normalized.map(\.rawValue).joined(separator: ","), forKey: Key.tabOrder)
        if !NativeAppTab.startTabCandidates.contains(startTab) {
            startTab = .home
            defaults.set(startTab.rawValue, forKey: Key.startTab)
        }
    }

    static func normalizedTabs(
        selectedKeys: [String],
        preferredOrder: [String],
        accountInHome _: Bool
    ) -> [NativeAppTab] {
        let allowed = Set(NativeAppTab.bottomBarCandidates)
        var selection = Set(selectedKeys.compactMap(NativeAppTab.init(rawValue:))).intersection(allowed)
        if selection.isEmpty {
            selection.insert(.home)
        }

        var ordered: [NativeAppTab] = []
        for tab in preferredOrder.compactMap(NativeAppTab.init(rawValue:))
            where selection.contains(tab) && !ordered.contains(tab) {
            ordered.append(tab)
        }
        for tab in NativeAppTab.bottomBarCandidates where selection.contains(tab) && !ordered.contains(tab) {
            ordered.append(tab)
        }
        return ordered
    }

    private static func defaultSelection(accountInHome _: Bool) -> [NativeAppTab] {
        NativeAppTab.bottomBarCandidates
    }

    private static func bool(_ defaults: UserDefaults, key: String, defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
