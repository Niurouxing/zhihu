import Foundation
import XCTest
@testable import iosApp

@MainActor
final class NativeTranslationAvailabilityTests: XCTestCase {
    func testSupportedLanguagesAreDeduplicatedAndLocalized() async {
        guard #available(iOS 18.0, *) else { return }
        let provider = TranslationProviderStub(
            languages: [
                Locale.Language(identifier: "zh-Hans"),
                Locale.Language(identifier: "en-US"),
                Locale.Language(identifier: "en-US"),
            ],
            pairStatus: .installed
        )
        let adapter = NativeTranslationAvailabilityAdapter(
            locale: Locale(identifier: "zh-Hans"),
            providerFactory: { provider }
        )

        await adapter.loadSupportedLanguages()

        XCTAssertEqual(Set(adapter.languageOptions.map(\.id)).count, 2)
        XCTAssertTrue(adapter.isConfiguredTargetSupported("en-US"))
        XCTAssertFalse(adapter.isConfiguredTargetSupported(nil))
    }

    func testPairAndTextStatusUseAppleAvailabilityBoundary() async {
        guard #available(iOS 18.0, *) else { return }
        let provider = TranslationProviderStub(
            languages: [Locale.Language(identifier: "en")],
            pairStatus: .supported
        )
        let adapter = NativeTranslationAvailabilityAdapter(providerFactory: { provider })

        let pair = await adapter.status(
            sourceLanguageIdentifier: "zh-Hans",
            targetLanguageIdentifier: "en"
        )
        let text = await adapter.status(text: "正文", targetLanguageIdentifier: "en")

        XCTAssertEqual(pair, .supported)
        XCTAssertEqual(text, .supported)
    }

    func testBlankTextAndBlankSourceAreRejectedWithoutProviderCall() async {
        guard #available(iOS 18.0, *) else { return }
        let provider = TranslationProviderStub(languages: [], pairStatus: .installed)
        let adapter = NativeTranslationAvailabilityAdapter(providerFactory: { provider })

        let pairStatus = await adapter.status(sourceLanguageIdentifier: " ", targetLanguageIdentifier: "en")
        let textStatus = await adapter.status(text: "\n", targetLanguageIdentifier: "en")
        XCTAssertEqual(pairStatus, .unsupported)
        XCTAssertEqual(textStatus, .unsupported)
        XCTAssertEqual(provider.statusCallCount, 0)
    }
}

@available(iOS 18.0, *)
private final class TranslationProviderStub: NativeTranslationAvailabilityProviding {
    let languages: [Locale.Language]
    let pairStatus: NativeTranslationLanguagePairStatus
    var statusCallCount = 0

    init(languages: [Locale.Language], pairStatus: NativeTranslationLanguagePairStatus) {
        self.languages = languages
        self.pairStatus = pairStatus
    }

    func supportedLanguages() async throws -> [Locale.Language] { languages }

    func status(
        from source: Locale.Language,
        to target: Locale.Language?
    ) async throws -> NativeTranslationLanguagePairStatus {
        statusCallCount += 1
        return pairStatus
    }

    func status(
        for text: String,
        to target: Locale.Language?
    ) async throws -> NativeTranslationLanguagePairStatus {
        statusCallCount += 1
        return pairStatus
    }
}
