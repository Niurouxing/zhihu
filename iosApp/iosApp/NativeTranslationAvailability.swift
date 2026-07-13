import Foundation
import Translation

struct NativeTranslationLanguageOption: Identifiable, Equatable, Sendable {
    let id: String
    let localizedName: String
}

enum NativeTranslationLanguagePairStatus: Equatable, Sendable {
    case installed
    case supported
    case unsupported
    case unavailable(String)
}

enum NativeTranslationAvailabilityState: Equatable, Sendable {
    case unavailableOnSystem
    case loading
    case available([NativeTranslationLanguageOption])
    case failed(String)
}

@available(iOS 18.0, *)
protocol NativeTranslationAvailabilityProviding: AnyObject {
    func supportedLanguages() async throws -> [Locale.Language]
    func status(from source: Locale.Language, to target: Locale.Language?) async throws
        -> NativeTranslationLanguagePairStatus
    func status(for text: String, to target: Locale.Language?) async throws
        -> NativeTranslationLanguagePairStatus
}

@available(iOS 18.0, *)
final class AppleTranslationAvailabilityProvider: NativeTranslationAvailabilityProviding {
    private let availability: LanguageAvailability

    init(availability: LanguageAvailability = LanguageAvailability()) {
        self.availability = availability
    }

    func supportedLanguages() async throws -> [Locale.Language] {
        await availability.supportedLanguages
    }

    func status(
        from source: Locale.Language,
        to target: Locale.Language?
    ) async throws -> NativeTranslationLanguagePairStatus {
        await availability.status(from: source, to: target).nativeStatus
    }

    func status(
        for text: String,
        to target: Locale.Language?
    ) async throws -> NativeTranslationLanguagePairStatus {
        try await availability.status(for: text, to: target).nativeStatus
    }
}

@MainActor
final class NativeTranslationAvailabilityAdapter: ObservableObject {
    @Published private(set) var state: NativeTranslationAvailabilityState

    private let locale: Locale
    private let providerFactory: () -> AnyObject?

    init(
        locale: Locale = .current,
        providerFactory: @escaping () -> AnyObject? = {
            guard #available(iOS 18.0, *) else { return nil }
            return AppleTranslationAvailabilityProvider()
        }
    ) {
        self.locale = locale
        self.providerFactory = providerFactory
        state = if #available(iOS 18.0, *) { .loading } else { .unavailableOnSystem }
    }

    var languageOptions: [NativeTranslationLanguageOption] {
        guard case let .available(options) = state else { return [] }
        return options
    }

    func loadSupportedLanguages() async {
        guard #available(iOS 18.0, *),
              let provider = providerFactory() as? NativeTranslationAvailabilityProviding
        else {
            state = .unavailableOnSystem
            return
        }
        state = .loading
        do {
            let languages = try await provider.supportedLanguages()
            let options = languages
                .map { language in
                    let identifier = language.minimalIdentifier
                    let name = locale.localizedString(forIdentifier: identifier) ?? identifier
                    return NativeTranslationLanguageOption(id: identifier, localizedName: name)
                }
                .reduce(into: [String: NativeTranslationLanguageOption]()) { result, option in
                    result[option.id] = option
                }
                .values
                .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
            state = .available(options)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func status(
        sourceLanguageIdentifier: String,
        targetLanguageIdentifier: String?
    ) async -> NativeTranslationLanguagePairStatus {
        guard #available(iOS 18.0, *),
              let provider = providerFactory() as? NativeTranslationAvailabilityProviding,
              let sourceIdentifier = sourceLanguageIdentifier.nativeNonBlank
        else { return .unsupported }
        let target = targetLanguageIdentifier?.nativeNonBlank.map(Locale.Language.init(identifier:))
        do {
            return try await provider.status(
                from: Locale.Language(identifier: sourceIdentifier),
                to: target
            )
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func status(
        text: String,
        targetLanguageIdentifier: String?
    ) async -> NativeTranslationLanguagePairStatus {
        guard #available(iOS 18.0, *),
              let provider = providerFactory() as? NativeTranslationAvailabilityProviding,
              let content = text.nativeNonBlank
        else { return .unsupported }
        let target = targetLanguageIdentifier?.nativeNonBlank.map(Locale.Language.init(identifier:))
        do {
            return try await provider.status(for: content, to: target)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func isConfiguredTargetSupported(_ identifier: String?) -> Bool {
        guard #available(iOS 18.0, *), let identifier = identifier?.nativeNonBlank else { return false }
        return languageOptions.contains { $0.id == Locale.Language(identifier: identifier).minimalIdentifier }
    }
}

@available(iOS 18.0, *)
private extension LanguageAvailability.Status {
    var nativeStatus: NativeTranslationLanguagePairStatus {
        switch self {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }
}

private extension String {
    var nativeNonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
