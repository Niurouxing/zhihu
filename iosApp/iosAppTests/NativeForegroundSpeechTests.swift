import AVFAudio
import XCTest
@testable import iosApp

@MainActor
final class NativeForegroundSpeechTests: XCTestCase {
    func testEmptySegmentsStopWithoutEnqueueing() {
        let driver = SpeechDriverSpy()
        let service = NativeForegroundSpeechService(driver: driver, voiceProvider: { [] })

        service.speak(segments: [" ", "\n"])

        XCTAssertEqual(service.state, .idle)
        XCTAssertTrue(driver.requests.isEmpty)
        XCTAssertEqual(driver.stopCount, 1)
    }

    func testMultipleSegmentsUseOneBatchAndFinishAfterLastUtterance() throws {
        let driver = SpeechDriverSpy()
        let service = NativeForegroundSpeechService(driver: driver, voiceProvider: { [] })

        service.speak(segments: ["第一段", "第二段"])

        XCTAssertEqual(service.state, .speaking)
        XCTAssertEqual(driver.requests.map(\.text), ["第一段", "第二段"])
        driver.emit(.didFinish(driver.requests[0].id))
        XCTAssertEqual(service.state, .speaking)
        driver.emit(.didFinish(driver.requests[1].id))
        XCTAssertEqual(service.state, .idle)
    }

    func testStaleCancellationFromReplacedBatchCannotStopNewSpeech() throws {
        let driver = SpeechDriverSpy()
        let service = NativeForegroundSpeechService(driver: driver, voiceProvider: { [] })
        service.speak(segments: ["旧内容"])
        let staleID = try XCTUnwrap(driver.requests.last?.id)

        service.speak(segments: ["新内容"])
        driver.emit(.didCancel(staleID))

        XCTAssertEqual(service.state, .speaking)
    }

    func testUnavailableVoiceFallsBackAndExposesWarning() {
        let driver = SpeechDriverSpy()
        let service = NativeForegroundSpeechService(driver: driver, voiceProvider: { [] })

        service.speak(
            segments: ["正文"],
            configuration: .init(voiceIdentifier: "removed.voice")
        )

        XCTAssertEqual(service.warning, .voiceUnavailable(identifier: "removed.voice"))
        XCTAssertNil(driver.requests.first?.voiceIdentifier)
    }

    func testInvalidRateUsesSystemDefaultAndExposesWarning() {
        let driver = SpeechDriverSpy()
        let service = NativeForegroundSpeechService(driver: driver, voiceProvider: { [] })

        service.speak(
            segments: ["正文"],
            configuration: .init(rate: .infinity)
        )

        XCTAssertEqual(service.warning, .invalidRate(.infinity))
        XCTAssertEqual(driver.requests.first?.rate, AVSpeechUtteranceDefaultSpeechRate)
    }

    func testPauseResumeAndStopReflectDriverSuccess() {
        let driver = SpeechDriverSpy()
        let service = NativeForegroundSpeechService(driver: driver, voiceProvider: { [] })
        service.speak(segments: ["正文"])

        service.pause()
        XCTAssertEqual(service.state, .paused)
        service.resume()
        XCTAssertEqual(service.state, .speaking)
        service.stop()
        XCTAssertEqual(service.state, .idle)
    }
}

@MainActor
private final class SpeechDriverSpy: NativeSpeechSynthesizerDriving {
    var eventHandler: ((NativeSpeechSynthesizerEvent) -> Void)?
    var isSpeaking = false
    var isPaused = false
    var requests: [NativeSpeechUtteranceRequest] = []
    var stopCount = 0

    func speak(_ request: NativeSpeechUtteranceRequest) {
        requests.append(request)
        isSpeaking = true
    }

    func pause() -> Bool {
        guard isSpeaking else { return false }
        isPaused = true
        return true
    }

    func resume() -> Bool {
        guard isPaused else { return false }
        isPaused = false
        return true
    }

    func stop() -> Bool {
        stopCount += 1
        isSpeaking = false
        isPaused = false
        return true
    }

    func emit(_ event: NativeSpeechSynthesizerEvent) {
        eventHandler?(event)
    }
}
