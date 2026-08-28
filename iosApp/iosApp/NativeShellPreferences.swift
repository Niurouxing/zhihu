import Foundation
import SwiftUI

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

enum NativeExternalPageOpeningMode: String, CaseIterable, Identifiable {
    case inApp
    case defaultBrowser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inApp: return "应用内"
        case .defaultBrowser: return "默认浏览器"
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
    enum Key {
        static let themeMode = "themeMode"
        static let contentFontSize = "contentFontSize"
        static let contentLineHeight = "contentLineHeight"
        static let contentBlockSpacing = "contentBlockSpacing"
        static let feedDensity = "nativeFeedDensity"
        static let feedExcerptLines = "nativeFeedExcerptLines"
        static let showFeedThumbnail = "showFeedThumbnail"
        static let homeRecommendationSource = "homeRecommendationSource"
        static let homeRefreshTargetItemCount = "homeRefreshTargetItemCount"
        static let showSearchHotSearch = "showSearchHotSearch"
        static let showSearchHistory = "showSearchHistory"
        static let shareActionMode = "shareActionMode"
        static let externalPageOpeningMode = "externalPageOpeningMode"
        static let hapticsEnabled = "nativeHapticsEnabled"
        static let hapticStrength = "nativeHapticStrength"
    }

    private let defaults: UserDefaults

    @Published private(set) var themeMode: NativeThemeMode
    @Published private(set) var contentFontSizePercent: Int
    @Published private(set) var contentLineHeightPercent: Int
    @Published private(set) var contentBlockSpacingPercent: Int
    @Published private(set) var feedDensity: NativeFeedDensity
    @Published private(set) var feedExcerptLines: Int
    @Published private(set) var showsFeedThumbnails: Bool
    @Published private(set) var homeRecommendationSource: HomeRecommendationSource
    @Published private(set) var homeRefreshTargetItemCount: Int
    @Published private(set) var showsSearchHotSearch: Bool
    @Published private(set) var showsSearchHistory: Bool
    @Published private(set) var defaultShareAction: NativeDefaultShareAction
    @Published private(set) var externalPageOpeningMode: NativeExternalPageOpeningMode
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

    var homeRecommendationRefreshConfiguration: HomeRecommendationRefreshConfiguration {
        HomeRecommendationRefreshConfiguration(
            source: homeRecommendationSource,
            targetItemCount: homeRefreshTargetItemCount
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
        let rawTheme = defaults.string(forKey: Key.themeMode) ?? NativeThemeMode.system.rawValue
        themeMode = NativeThemeMode(rawValue: rawTheme) ?? .system
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
        homeRecommendationSource = defaults.string(forKey: Key.homeRecommendationSource)
            .flatMap(HomeRecommendationSource.init(rawValue:)) ?? .app
        homeRefreshTargetItemCount = Self.clamp(
            defaults.object(forKey: Key.homeRefreshTargetItemCount) == nil
                ? HomeRecommendationRefreshConfiguration.defaultValue.targetItemCount
                : defaults.integer(forKey: Key.homeRefreshTargetItemCount),
            to: HomeRecommendationRefreshConfiguration.targetItemRange
        )
        showsSearchHotSearch = Self.bool(defaults, key: Key.showSearchHotSearch, defaultValue: true)
        showsSearchHistory = Self.bool(defaults, key: Key.showSearchHistory, defaultValue: true)
        defaultShareAction = defaults.string(forKey: Key.shareActionMode)
            .flatMap(NativeDefaultShareAction.init(rawValue:)) ?? .ask
        externalPageOpeningMode = defaults.string(forKey: Key.externalPageOpeningMode)
            .flatMap(NativeExternalPageOpeningMode.init(rawValue:)) ?? .defaultBrowser
        hapticsEnabled = Self.bool(defaults, key: Key.hapticsEnabled, defaultValue: true)
        hapticStrength = defaults.string(forKey: Key.hapticStrength)
            .flatMap(NativeHapticStrength.init(rawValue:)) ?? .standard
    }

    func setThemeMode(_ mode: NativeThemeMode) {
        guard themeMode != mode else { return }
        themeMode = mode
        defaults.set(mode.rawValue, forKey: Key.themeMode)
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

    func setHomeRecommendationSource(_ source: HomeRecommendationSource) {
        guard homeRecommendationSource != source else { return }
        homeRecommendationSource = source
        defaults.set(source.rawValue, forKey: Key.homeRecommendationSource)
    }

    func setHomeRefreshTargetItemCount(_ value: Int) {
        let value = Self.clamp(
            value,
            to: HomeRecommendationRefreshConfiguration.targetItemRange
        )
        guard homeRefreshTargetItemCount != value else { return }
        homeRefreshTargetItemCount = value
        defaults.set(value, forKey: Key.homeRefreshTargetItemCount)
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

    func setDefaultShareAction(_ action: NativeDefaultShareAction) {
        guard defaultShareAction != action else { return }
        defaultShareAction = action
        defaults.set(action.rawValue, forKey: Key.shareActionMode)
    }

    func setExternalPageOpeningMode(_ mode: NativeExternalPageOpeningMode) {
        guard externalPageOpeningMode != mode else { return }
        externalPageOpeningMode = mode
        defaults.set(mode.rawValue, forKey: Key.externalPageOpeningMode)
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

    private static func bool(_ defaults: UserDefaults, key: String, defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
