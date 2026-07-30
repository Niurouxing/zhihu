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

    func testDiagnosticEndpointContainsOnlyTemplateAndQueryKeys() throws {
        let url = try XCTUnwrap(URL(
            string: "https://api.zhihu.com/questions/123456/answers/secret-member?limit=20&q=private-search&token=top-secret"
        ))
        let endpoint = try XCTUnwrap(PerformanceDiagnosticEndpoint(url: url))

        XCTAssertEqual(endpoint.host, "api.zhihu.com")
        XCTAssertEqual(endpoint.pathTemplate, "/questions/:id/answers/:id")
        XCTAssertEqual(endpoint.queryKeys, ["limit", "q", "token"])
        let encoded = String(decoding: try JSONEncoder().encode(endpoint), as: UTF8.self)
        XCTAssertFalse(encoded.contains("123456"))
        XCTAssertFalse(encoded.contains("secret-member"))
        XCTAssertFalse(encoded.contains("private-search"))
        XCTAssertFalse(encoded.contains("top-secret"))
    }

    func testDiagnosticWriterFinalizesShareableJSONLWithoutSecrets() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = PerformanceDiagnosticLogWriter(
            directory: directory,
            context: .init(
                appVersion: "1.0",
                appBuild: "1",
                osVersion: "Test OS",
                deviceModel: "Test Device"
            )
        )
        await writer.startSession()
        let endpoint = try XCTUnwrap(PerformanceDiagnosticEndpoint(url: URL(
            string: "https://api.zhihu.com/search_v3?q=private-search&access_token=top-secret"
        )!))
        await writer.record(.init(
            durationMilliseconds: 12.5,
            category: "network",
            operation: "zhihu_api_request",
            result: .success,
            endpoint: endpoint,
            httpStatus: 200,
            responseBytes: 42
        ))
        await writer.finalizeSession()

        let logs = await writer.logs()
        XCTAssertEqual(logs.count, 1)
        let contents = try String(contentsOf: XCTUnwrap(logs.first?.url), encoding: .utf8)
        XCTAssertTrue(contents.contains("\"operation\":\"zhihu_api_request\""))
        XCTAssertTrue(contents.contains("\"queryKeys\":[\"access_token\",\"q\"]"))
        XCTAssertTrue(contents.contains("\"deviceModel\":\"Test Device\""))
        XCTAssertFalse(contents.contains("private-search"))
        XCTAssertFalse(contents.contains("top-secret"))
        XCTAssertFalse(contents.contains("Cookie"))
    }

    func testDiagnosticWriterRetainsLatestSessionsAndSupportsDelete() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = PerformanceDiagnosticLogWriter(
            directory: directory,
            context: .init(
                appVersion: "1.0",
                appBuild: "1",
                osVersion: "Test OS",
                deviceModel: "Test Device"
            ),
            maximumSessionCount: 2
        )

        for _ in 0..<3 {
            await writer.startSession()
            await writer.finalizeSession()
        }
        var logs = await writer.logs()
        XCTAssertEqual(logs.count, 2)

        if let first = logs.first {
            await writer.delete(first.url)
        }
        logs = await writer.logs()
        XCTAssertEqual(logs.count, 1)

        await writer.deleteAll()
        logs = await writer.logs()
        XCTAssertTrue(logs.isEmpty)
    }

    func testDiagnosticWriterRollsOverAndRetainsFiveSessions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = PerformanceDiagnosticLogWriter(
            directory: directory,
            context: .init(
                appVersion: "1.0",
                appBuild: "1",
                osVersion: "Test OS",
                deviceModel: "Test Device"
            ),
            maximumSessionBytes: 2_048,
            maximumSessionCount: 5
        )
        await writer.startSession()
        for _ in 0..<100 {
            await writer.record(.init(
                durationMilliseconds: 1,
                category: "network",
                operation: "zhihu_api_request",
                result: .success,
                httpStatus: 200,
                responseBytes: 10
            ))
        }
        await writer.finalizeSession()

        let logs = await writer.logs()
        XCTAssertEqual(logs.count, 5)
        let contents = try logs.map {
            try String(contentsOf: $0.url, encoding: .utf8)
        }.joined()
        XCTAssertTrue(contents.contains("\"operation\":\"rollover\""))
    }

    func testDiagnosticsToggleFinalizesQueuedEventsAndReenableStartsNewSession() async throws {
        let defaults = isolatedDefaults()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = NativePerformanceDiagnosticsController(
            defaults: defaults,
            directory: directory
        )

        controller.setEnabled(true)
        controller.client.record(.init(
            category: "navigation",
            operation: "push",
            result: .success,
            routeType: "answer"
        ))
        controller.setEnabled(false)
        await controller.refreshLogs()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.logs.count, 1)
        let finalizedLog = try XCTUnwrap(controller.logs.first)
        let preparedURL = await controller.shareURL(for: finalizedLog)
        let finalizedURL = try XCTUnwrap(preparedURL)
        let finalizedContents = try String(contentsOf: finalizedURL, encoding: .utf8)
        XCTAssertTrue(finalizedContents.contains("\"operation\":\"push\""))
        XCTAssertTrue(finalizedContents.contains("\"operation\":\"finalize\""))

        controller.client.record(.init(
            category: "navigation",
            operation: "disabled_event_must_not_leak",
            result: .success
        ))
        controller.setEnabled(true)
        await controller.refreshLogs()
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.logs.count, 2)

        controller.client.record(.init(
            category: "navigation",
            operation: "enabled_after_restart",
            result: .success
        ))
        controller.setEnabled(false)
        await controller.refreshLogs()
        let allContents = try controller.logs.map {
            try String(contentsOf: $0.url, encoding: .utf8)
        }.joined()
        XCTAssertTrue(allContents.contains("enabled_after_restart"))
        XCTAssertFalse(allContents.contains("disabled_event_must_not_leak"))
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "NativeSystemIntegrationSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NativePerformanceDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
    }
}
