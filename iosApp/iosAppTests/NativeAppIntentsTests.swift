import AppIntents
import XCTest
@testable import iosApp

@MainActor
@available(iOS 16.0, *)
final class NativeAppIntentsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SystemNavigationRequestCenter.shared.resetForTesting()
    }

    override func tearDown() {
        SystemNavigationRequestCenter.shared.resetForTesting()
        super.tearDown()
    }

    func testRequestWaitsUntilShellInstallsHandler() {
        SystemNavigationRequestCenter.shared.submit(.hot)
        var received: SystemNavigationRequestEnvelope?

        SystemNavigationRequestCenter.shared.installHandler { received = $0 }

        XCTAssertEqual(received?.request, .hot)
        XCTAssertNil(SystemNavigationRequestCenter.shared.pendingRequestForTesting)
    }

    func testSearchIntentTrimsQueryAndOnlyHandsOffNavigation() async throws {
        var received: SystemNavigationRequestEnvelope?
        SystemNavigationRequestCenter.shared.installHandler { received = $0 }
        let intent = OpenZhihuSearchIntent()
        intent.query = "  SwiftUI  "

        _ = try await intent.perform()

        XCTAssertEqual(received?.request, .search(query: "SwiftUI"))
    }

    func testAllNonParameterizedIntentsSubmitTypedRequests() async throws {
        var received: [SystemNavigationRequest] = []
        SystemNavigationRequestCenter.shared.installHandler { received.append($0.request) }

        _ = try await OpenZhihuHotIntent().perform()
        _ = try await OpenZhihuCollectionsIntent().perform()

        XCTAssertEqual(received, [.hot, .collections])
    }
}
