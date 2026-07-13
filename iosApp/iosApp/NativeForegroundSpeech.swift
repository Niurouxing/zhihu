import AVFAudio
import Foundation

struct NativeSpeechVoiceOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let languageIdentifier: String
    let quality: AVSpeechSynthesisVoiceQuality
}

struct NativeSpeechPlaybackConfiguration: Equatable, Sendable {
    let languageIdentifier: String?
    let voiceIdentifier: String?
    let rate: Float?

    init(languageIdentifier: String? = nil, voiceIdentifier: String? = nil, rate: Float? = nil) {
        self.languageIdentifier = languageIdentifier?.nativeNonBlank
        self.voiceIdentifier = voiceIdentifier?.nativeNonBlank
        self.rate = rate
    }
}

enum NativeSpeechPlaybackState: Equatable {
    case idle
    case speaking
    case paused
}

enum NativeSpeechPlaybackWarning: Equatable {
    case voiceUnavailable(identifier: String)
    case invalidRate(Float)

    var message: String {
        switch self {
        case let .voiceUnavailable(identifier):
            return "所选系统语音已不可用，已改用当前语言的系统语音（\(identifier)）"
        case let .invalidRate(rate):
            return "朗读速度超出系统支持范围，已恢复系统速度（\(rate)）"
        }
    }
}

struct NativeSpeechUtteranceRequest: Equatable {
    let id: UUID
    let text: String
    let languageIdentifier: String?
    let voiceIdentifier: String?
    let rate: Float
}

enum NativeSpeechSynthesizerEvent: Equatable {
    case didStart(UUID)
    case didFinish(UUID)
    case didCancel(UUID)
}

@MainActor
protocol NativeSpeechSynthesizerDriving: AnyObject {
    var eventHandler: ((NativeSpeechSynthesizerEvent) -> Void)? { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }

    func speak(_ request: NativeSpeechUtteranceRequest)
    @discardableResult func pause() -> Bool
    @discardableResult func resume() -> Bool
    @discardableResult func stop() -> Bool
}

@MainActor
final class AVSpeechSynthesizerDriver: NSObject, NativeSpeechSynthesizerDriving {
    var eventHandler: ((NativeSpeechSynthesizerEvent) -> Void)?

    var isSpeaking: Bool { synthesizer.isSpeaking }
    var isPaused: Bool { synthesizer.isPaused }

    private let synthesizer: AVSpeechSynthesizer
    private var requestIDs: [ObjectIdentifier: UUID] = [:]

    override init() {
        synthesizer = AVSpeechSynthesizer()
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ request: NativeSpeechUtteranceRequest) {
        let utterance = AVSpeechUtterance(string: request.text)
        if let identifier = request.voiceIdentifier {
            utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
        } else if let language = request.languageIdentifier {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        utterance.rate = request.rate
        requestIDs[ObjectIdentifier(utterance)] = request.id
        synthesizer.speak(utterance)
    }

    func pause() -> Bool {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() -> Bool {
        synthesizer.continueSpeaking()
    }

    func stop() -> Bool {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func emit(_ makeEvent: (UUID) -> NativeSpeechSynthesizerEvent, for utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        guard let requestID = requestIDs[key] else { return }
        let event = makeEvent(requestID)
        if case .didFinish = event {
            requestIDs[key] = nil
        } else if case .didCancel = event {
            requestIDs[key] = nil
        }
        eventHandler?(event)
    }
}

extension AVSpeechSynthesizerDriver: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.emit(NativeSpeechSynthesizerEvent.didStart, for: utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.emit(NativeSpeechSynthesizerEvent.didFinish, for: utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.emit(NativeSpeechSynthesizerEvent.didCancel, for: utterance) }
    }
}

@MainActor
final class NativeForegroundSpeechService: ObservableObject {
    @Published private(set) var state: NativeSpeechPlaybackState = .idle
    @Published private(set) var warning: NativeSpeechPlaybackWarning?

    var availableVoices: [NativeSpeechVoiceOption] {
        voiceProvider()
            .map {
                NativeSpeechVoiceOption(
                    id: $0.identifier,
                    name: $0.name,
                    languageIdentifier: $0.language,
                    quality: $0.quality
                )
            }
            .sorted {
                if $0.languageIdentifier == $1.languageIdentifier { return $0.name < $1.name }
                return $0.languageIdentifier < $1.languageIdentifier
            }
    }

    var isAvailable: Bool { !availableVoices.isEmpty }

    private let driver: NativeSpeechSynthesizerDriving
    private let voiceProvider: () -> [AVSpeechSynthesisVoice]
    private var activeBatchID: UUID?
    private var requestBatchIDs: [UUID: UUID] = [:]

    init(
        driver: NativeSpeechSynthesizerDriving? = nil,
        voiceProvider: @escaping () -> [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices
    ) {
        let driver = driver ?? AVSpeechSynthesizerDriver()
        self.driver = driver
        self.voiceProvider = voiceProvider
        driver.eventHandler = { [weak self] event in self?.handle(event) }
    }

    func speak(segments: [String], configuration: NativeSpeechPlaybackConfiguration = .init()) {
        let texts = segments.compactMap(\.nativeNonBlank)
        guard !texts.isEmpty else {
            stop()
            return
        }

        _ = driver.stop()
        warning = nil
        requestBatchIDs.removeAll()

        let voices = voiceProvider()
        let resolvedVoice = resolveVoice(
            identifier: configuration.voiceIdentifier,
            languageIdentifier: configuration.languageIdentifier,
            voices: voices
        )
        let rate = resolveRate(configuration.rate)
        let batchID = UUID()
        activeBatchID = batchID
        state = .speaking

        for text in texts {
            let requestID = UUID()
            requestBatchIDs[requestID] = batchID
            driver.speak(
                NativeSpeechUtteranceRequest(
                    id: requestID,
                    text: text,
                    languageIdentifier: configuration.languageIdentifier,
                    voiceIdentifier: resolvedVoice?.identifier,
                    rate: rate
                )
            )
        }
    }

    func pause() {
        guard state == .speaking, driver.pause() else { return }
        state = .paused
    }

    func resume() {
        guard state == .paused, driver.resume() else { return }
        state = .speaking
    }

    func stop() {
        _ = driver.stop()
        activeBatchID = nil
        requestBatchIDs.removeAll()
        state = .idle
    }

    func clearWarning() {
        warning = nil
    }

    private func resolveVoice(
        identifier: String?,
        languageIdentifier: String?,
        voices: [AVSpeechSynthesisVoice]
    ) -> AVSpeechSynthesisVoice? {
        if let identifier {
            if let selected = voices.first(where: { $0.identifier == identifier }) { return selected }
            warning = .voiceUnavailable(identifier: identifier)
        }
        guard let languageIdentifier else { return nil }
        let normalizedLanguage = languageIdentifier.nativeLanguageCode
        return voices.first {
            guard let normalizedLanguage else { return $0.language == languageIdentifier }
            return $0.language.nativeLanguageCode == normalizedLanguage
        }
    }

    private func resolveRate(_ rate: Float?) -> Float {
        guard let rate else { return AVSpeechUtteranceDefaultSpeechRate }
        guard rate.isFinite,
              rate >= AVSpeechUtteranceMinimumSpeechRate,
              rate <= AVSpeechUtteranceMaximumSpeechRate
        else {
            warning = .invalidRate(rate)
            return AVSpeechUtteranceDefaultSpeechRate
        }
        return rate
    }

    private func handle(_ event: NativeSpeechSynthesizerEvent) {
        let requestID: UUID
        switch event {
        case let .didStart(id), let .didFinish(id), let .didCancel(id): requestID = id
        }
        guard let batchID = requestBatchIDs[requestID], batchID == activeBatchID else { return }

        switch event {
        case .didStart:
            if state != .paused { state = .speaking }
        case .didFinish, .didCancel:
            requestBatchIDs[requestID] = nil
            if requestBatchIDs.values.allSatisfy({ $0 != batchID }) {
                activeBatchID = nil
                state = .idle
            }
        }
    }
}

private extension String {
    var nativeNonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nativeLanguageCode: String? {
        nativeNonBlank?
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map { String($0).lowercased() }
    }
}
