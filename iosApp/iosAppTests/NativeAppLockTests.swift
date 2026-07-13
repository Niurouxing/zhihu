import XCTest
@testable import iosApp

@MainActor
final class NativeAppLockTests: XCTestCase {
    func testHostedAppProvidesNonEmptyFaceIDUsageDescription() throws {
        let description = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String
        )
        XCTAssertFalse(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testUnavailableCapabilityCannotBeNewlyEnabled() {
        let authenticator = AppLockAuthenticatorStub(
            capability: .unavailable(.biometryNotEnrolled),
            result: .authenticated
        )
        let coordinator = NativeAppLockCoordinator(storedPreference: nil, authenticator: authenticator)

        coordinator.updatePreference(true)

        XCTAssertEqual(coordinator.state, .unlocked)
        XCTAssertFalse(coordinator.settingPresentation.isVisible)
        XCTAssertFalse(coordinator.settingPresentation.canEnable)
    }

    func testPreviouslyEnabledLockRemainsVisibleAndLockedWhenBiometryBecomesUnavailable() {
        let authenticator = AppLockAuthenticatorStub(
            capability: .unavailable(.biometryLockedOut),
            result: .failed("已锁定")
        )
        let coordinator = NativeAppLockCoordinator(storedPreference: true, authenticator: authenticator)

        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertTrue(coordinator.settingPresentation.isVisible)
        XCTAssertFalse(coordinator.settingPresentation.canEnable)
        XCTAssertEqual(coordinator.settingPresentation.unavailableReason, .biometryLockedOut)
    }

    func testUnlockUsesAuthenticatorAndTransitionsToUnlocked() async {
        let authenticator = AppLockAuthenticatorStub(
            capability: .available(.faceID),
            result: .authenticated
        )
        let coordinator = NativeAppLockCoordinator(storedPreference: true, authenticator: authenticator)

        await coordinator.unlockIfNeeded()

        XCTAssertEqual(coordinator.state, .unlocked)
        XCTAssertEqual(authenticator.reasons, ["解锁知乎++"])
    }

    func testFailedAuthenticationNeverBypassesEnabledLock() async {
        let authenticator = AppLockAuthenticatorStub(
            capability: .available(.touchID),
            result: .failed("用户取消")
        )
        let coordinator = NativeAppLockCoordinator(storedPreference: true, authenticator: authenticator)

        await coordinator.unlockIfNeeded()

        XCTAssertEqual(coordinator.state, .failed("用户取消"))
        coordinator.lock()
        XCTAssertEqual(coordinator.state, .locked)
    }
}

@MainActor
private final class AppLockAuthenticatorStub: NativeAppLockAuthenticating {
    var capabilityValue: NativeAppLockCapability
    var result: NativeAppLockAuthenticationResult
    var reasons: [String] = []

    init(capability: NativeAppLockCapability, result: NativeAppLockAuthenticationResult) {
        capabilityValue = capability
        self.result = result
    }

    func capability() -> NativeAppLockCapability { capabilityValue }

    func authenticate(localizedReason: String) async -> NativeAppLockAuthenticationResult {
        reasons.append(localizedReason)
        return result
    }
}
