import AVFAudio
import Foundation

@MainActor
final class NativeSystemIntegrationSettings: ObservableObject {
    enum Key {
        static let spotlightIndexing = "nativeSystem.spotlightIndexing"
        static let appLock = "nativeSystem.appLock"
        static let translationTargetLanguage = "nativeSystem.translationTargetLanguage"
        static let speechVoiceIdentifier = "nativeSystem.speechVoiceIdentifier"
        static let speechRate = "nativeSystem.speechRate"
    }

    @Published private(set) var spotlightIndexing: Bool?
    @Published private(set) var appLock: Bool?
    @Published private(set) var translationTargetLanguageIdentifier: String?
    @Published private(set) var speechVoiceIdentifier: String?
    @Published private(set) var speechRate: Float?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        spotlightIndexing = defaults.object(forKey: Key.spotlightIndexing) as? Bool
        appLock = defaults.object(forKey: Key.appLock) as? Bool
        translationTargetLanguageIdentifier = defaults.string(forKey: Key.translationTargetLanguage)?.nonBlank
        speechVoiceIdentifier = defaults.string(forKey: Key.speechVoiceIdentifier)?.nonBlank
        if let number = defaults.object(forKey: Key.speechRate) as? NSNumber {
            let value = number.floatValue
            speechRate = Self.validSpeechRate(value) ? value : nil
        } else {
            speechRate = nil
        }
    }

    func setSpotlightIndexing(_ enabled: Bool) {
        spotlightIndexing = enabled
        defaults.set(enabled, forKey: Key.spotlightIndexing)
    }

    func setAppLock(_ enabled: Bool) {
        appLock = enabled
        defaults.set(enabled, forKey: Key.appLock)
    }

    func setTranslationTargetLanguageIdentifier(_ identifier: String?) {
        let value = identifier?.nonBlank
        translationTargetLanguageIdentifier = value
        defaults.set(value, forKey: Key.translationTargetLanguage)
    }

    func setSpeechVoiceIdentifier(_ identifier: String?) {
        let value = identifier?.nonBlank
        speechVoiceIdentifier = value
        defaults.set(value, forKey: Key.speechVoiceIdentifier)
    }

    func setSpeechRate(_ rate: Float?) {
        let value = rate.flatMap { Self.validSpeechRate($0) ? $0 : nil }
        speechRate = value
        defaults.set(value, forKey: Key.speechRate)
    }

    private static func validSpeechRate(_ rate: Float) -> Bool {
        rate.isFinite && rate >= AVSpeechUtteranceMinimumSpeechRate && rate <= AVSpeechUtteranceMaximumSpeechRate
    }
}

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
