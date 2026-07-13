import Foundation
import XCTest
@testable import iosApp

final class NativeSpotlightIndexTests: XCTestCase {
    func testRouteCodecRoundTripsTypedAnswer() throws {
        let item = SpotlightContentDTO(
            domain: .history,
            route: .answer(42),
            title: "回答",
            authorName: "作者",
            summary: "摘要",
            updatedAt: nil
        )
        XCTAssertEqual(
            SpotlightRouteCodec.route(fromSearchableItemIdentifier: item.uniqueIdentifier),
            .answer(42)
        )
        XCTAssertEqual(
            SpotlightRouteCodec.route(fromSearchableItemIdentifier: item.uniqueIdentifier)?.nativeDestination,
            .article(id: 42, kind: .answer)
        )
    }

    func testUnconfiguredPreferenceDoesNotMutateIndex() async throws {
        let writer = SpotlightWriterSpy()
        let coordinator = SpotlightIndexCoordinator(writer: writer)

        let result = try await coordinator.reconcile(preference: nil, snapshots: [:])
        let mutationCount = await writer.mutationCount

        XCTAssertEqual(result, .notConfigured)
        XCTAssertEqual(mutationCount, 0)
    }

    func testDisablingDeletesEveryOwnedDomain() async throws {
        let writer = SpotlightWriterSpy()
        let coordinator = SpotlightIndexCoordinator(writer: writer)

        let result = try await coordinator.reconcile(preference: false, snapshots: [:])
        let deletedDomains = await writer.deletedDomains

        XCTAssertEqual(result, .disabledAndDeleted)
        XCTAssertEqual(deletedDomains, SpotlightContentDomain.allCases)
    }

    func testEnabledReconciliationReplacesAllDomainsIncludingEmptyOnes() async throws {
        let writer = SpotlightWriterSpy()
        let coordinator = SpotlightIndexCoordinator(writer: writer)
        let dto = SpotlightContentDTO(
            domain: .collections,
            route: .article(8),
            title: "文章",
            authorName: nil,
            summary: nil,
            updatedAt: nil
        )

        let result = try await coordinator.reconcile(preference: true, snapshots: [.collections: [dto]])
        let replacedDomains = await writer.replacedDomains

        XCTAssertEqual(result, .indexed(1))
        XCTAssertEqual(replacedDomains, SpotlightContentDomain.allCases)
    }
}

private actor SpotlightWriterSpy: SpotlightIndexWriting {
    var mutationCount = 0
    var deletedDomains: [SpotlightContentDomain] = []
    var replacedDomains: [SpotlightContentDomain] = []

    func isAvailable() async -> Bool { true }

    func replace(_ items: [SpotlightContentDTO], in domain: SpotlightContentDomain) async throws {
        mutationCount += 1
        replacedDomains.append(domain)
    }

    func delete(domains: [SpotlightContentDomain]) async throws {
        mutationCount += 1
        deletedDomains = domains
    }
}
