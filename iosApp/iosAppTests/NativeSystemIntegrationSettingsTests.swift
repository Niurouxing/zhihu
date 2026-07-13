import AVFAudio
import Foundation
import XCTest
@testable import iosApp

@MainActor
final class NativeSystemIntegrationSettingsTests: XCTestCase {
    func testUnconfiguredValuesRemainNil() {
        let defaults = isolatedDefaults()
        let settings = NativeSystemIntegrationSettings(defaults: defaults)

        XCTAssertNil(settings.spotlightIndexing)
        XCTAssertNil(settings.appLock)
        XCTAssertNil(settings.translationTargetLanguageIdentifier)
        XCTAssertNil(settings.speechVoiceIdentifier)
        XCTAssertNil(settings.speechRate)
    }

    func testConfiguredValuesPersistWithoutInventingFallbacks() {
        let defaults = isolatedDefaults()
        let settings = NativeSystemIntegrationSettings(defaults: defaults)
        settings.setSpotlightIndexing(true)
        settings.setAppLock(true)
        settings.setTranslationTargetLanguageIdentifier("  zh-Hans  ")
        settings.setSpeechVoiceIdentifier(" voice-id ")
        settings.setSpeechRate(AVSpeechUtteranceDefaultSpeechRate)

        let restored = NativeSystemIntegrationSettings(defaults: defaults)
        XCTAssertEqual(restored.spotlightIndexing, true)
        XCTAssertEqual(restored.appLock, true)
        XCTAssertEqual(restored.translationTargetLanguageIdentifier, "zh-Hans")
        XCTAssertEqual(restored.speechVoiceIdentifier, "voice-id")
        XCTAssertEqual(restored.speechRate, AVSpeechUtteranceDefaultSpeechRate)
    }

    func testInvalidSpeechRateIsCleared() {
        let defaults = isolatedDefaults()
        let settings = NativeSystemIntegrationSettings(defaults: defaults)
        settings.setSpeechRate(.infinity)
        XCTAssertNil(settings.speechRate)
        XCTAssertNil(defaults.object(forKey: NativeSystemIntegrationSettings.Key.speechRate))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "NativeSystemIntegrationSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
