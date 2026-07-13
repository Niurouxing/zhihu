import XCTest
@testable import iosApp

@MainActor
final class NativeShellPreferencesTests: XCTestCase {
    func testAccountInHomeRemovesAccountTabWithoutLeavingEmptySlot() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: NativeShellPreferences.Key.accountInHome)
        defaults.set(["Home", "Follow", "Account"], forKey: NativeShellPreferences.Key.selectedTabs)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedTabs, [.home, .follow, .daily])
        XCTAssertFalse(preferences.selectedTabs.contains(.account))
    }

    func testOrdinaryModeKeepsAccountAndLimitsTabCount() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: NativeShellPreferences.Key.accountInHome)
        defaults.set(NativeAppTab.allCases.map(\.rawValue), forKey: NativeShellPreferences.Key.selectedTabs)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertTrue(preferences.selectedTabs.contains(.account))
        XCTAssertLessThanOrEqual(preferences.selectedTabs.count, 5)
    }

    func testDisablingTabsNeverDropsBelowThree() {
        let defaults = makeDefaults()
        let preferences = NativeShellPreferences(defaults: defaults)

        for tab in NativeAppTab.allCases {
            preferences.setTabEnabled(tab, enabled: false)
        }

        XCTAssertGreaterThanOrEqual(preferences.selectedTabs.count, 3)
    }

    func testInvalidThemeFallsBackWithoutOverwritingStoredRawValue() {
        let defaults = makeDefaults()
        defaults.set("FUTURE", forKey: NativeShellPreferences.Key.themeMode)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.themeMode, .system)
        XCTAssertEqual(defaults.string(forKey: NativeShellPreferences.Key.themeMode), "FUTURE")
    }

    func testRestoredReadingFeedSearchAndSharePreferencesConsumeLegacyKeys() {
        let defaults = makeDefaults()
        defaults.set(125, forKey: NativeShellPreferences.Key.contentFontSize)
        defaults.set(180, forKey: NativeShellPreferences.Key.contentLineHeight)
        defaults.set(130, forKey: NativeShellPreferences.Key.contentBlockSpacing)
        defaults.set(false, forKey: NativeShellPreferences.Key.showFeedThumbnail)
        defaults.set(false, forKey: NativeShellPreferences.Key.showSearchHotSearch)
        defaults.set(false, forKey: NativeShellPreferences.Key.showSearchHistory)
        defaults.set("off", forKey: NativeShellPreferences.Key.answerSwitchMode)
        defaults.set("copy", forKey: NativeShellPreferences.Key.shareActionMode)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.contentFontSizePercent, 125)
        XCTAssertEqual(preferences.contentLineHeightPercent, 180)
        XCTAssertEqual(preferences.contentBlockSpacingPercent, 130)
        XCTAssertFalse(preferences.showsFeedThumbnails)
        XCTAssertFalse(preferences.showsSearchHotSearch)
        XCTAssertFalse(preferences.showsSearchHistory)
        XCTAssertFalse(preferences.answerSwitchEnabled)
        XCTAssertEqual(preferences.defaultShareAction, .copyLink)
    }

    func testRestoredPreferenceSettersPersistSemanticValues() {
        let defaults = makeDefaults()
        let preferences = NativeShellPreferences(defaults: defaults)

        preferences.setFeedDensity(.compact)
        preferences.setFeedExcerptLines(4)
        preferences.setAnswerSwitchEnabled(false)
        preferences.setAnswerSwitchEnabled(true)
        preferences.setDefaultShareAction(.systemShare)

        XCTAssertEqual(defaults.string(forKey: NativeShellPreferences.Key.feedDensity), "compact")
        XCTAssertEqual(defaults.integer(forKey: NativeShellPreferences.Key.feedExcerptLines), 4)
        XCTAssertEqual(defaults.string(forKey: NativeShellPreferences.Key.answerSwitchMode), "horizontal")
        XCTAssertEqual(defaults.string(forKey: NativeShellPreferences.Key.shareActionMode), "share")
    }

    func testExpandedRootDoesNotRenderCompactToolbarTitle() {
        XCTAssertFalse(NativeRootCompactTitle.shouldRender(collapseProgress: 0))
        XCTAssertFalse(NativeRootCompactTitle.shouldRender(collapseProgress: 0.19))
        XCTAssertTrue(NativeRootCompactTitle.shouldRender(collapseProgress: 0.2))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "NativeShellPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
