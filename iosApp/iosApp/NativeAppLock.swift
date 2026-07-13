import Foundation
import LocalAuthentication

enum NativeBiometryKind: Equatable, Sendable {
    case touchID
    case faceID
    case opticID
}

enum NativeAppLockUnavailableReason: Equatable, Sendable {
    case biometryNotAvailable
    case biometryNotEnrolled
    case biometryLockedOut
    case passcodeNotSet
    case faceIDUsageDescriptionMissing
    case policyUnavailable
}

enum NativeAppLockCapability: Equatable, Sendable {
    case available(NativeBiometryKind)
    case unavailable(NativeAppLockUnavailableReason)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

struct NativeAppLockSettingPresentation: Equatable, Sendable {
    let isVisible: Bool
    let canEnable: Bool
    let unavailableReason: NativeAppLockUnavailableReason?

    init(capability: NativeAppLockCapability, storedPreference: Bool?) {
        switch capability {
        case .available:
            isVisible = true
            canEnable = true
            unavailableReason = nil
        case let .unavailable(reason):
            isVisible = storedPreference == true
            canEnable = false
            unavailableReason = reason
        }
    }
}

enum NativeAppLockAuthenticationResult: Equatable, Sendable {
    case authenticated
    case failed(String)
}

@MainActor
protocol NativeAppLockAuthenticating: AnyObject {
    func capability() -> NativeAppLockCapability
    func authenticate(localizedReason: String) async -> NativeAppLockAuthenticationResult
}

@MainActor
final class LocalAuthenticationAppLockAuthenticator: NativeAppLockAuthenticating {
    private let bundle: Bundle
    private let makeContext: () -> LAContext

    init(bundle: Bundle = .main, makeContext: @escaping () -> LAContext = LAContext.init) {
        self.bundle = bundle
        self.makeContext = makeContext
    }

    func capability() -> NativeAppLockCapability {
        let context = makeContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .unavailable(Self.unavailableReason(from: error))
        }

        switch context.biometryType {
        case .touchID:
            return .available(.touchID)
        case .faceID:
            guard let usageDescription = bundle.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String,
                  !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .unavailable(.faceIDUsageDescriptionMissing)
            }
            return .available(.faceID)
        case .none:
            return .unavailable(.biometryNotAvailable)
        default:
            if #available(iOS 17.0, *), context.biometryType == .opticID {
                return .available(.opticID)
            }
            return .unavailable(.policyUnavailable)
        }
    }

    func authenticate(localizedReason: String) async -> NativeAppLockAuthenticationResult {
        let reason = localizedReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return .failed("解锁原因不能为空") }

        let context = makeContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return .failed(policyError?.localizedDescription ?? "设备身份验证不可用")
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: .authenticated)
                } else {
                    continuation.resume(returning: .failed(error?.localizedDescription ?? "未能解锁"))
                }
            }
        }
    }

    private static func unavailableReason(from error: NSError?) -> NativeAppLockUnavailableReason {
        guard let code = error.flatMap({ LAError.Code(rawValue: $0.code) }) else {
            return .policyUnavailable
        }
        switch code {
        case .biometryNotAvailable: return .biometryNotAvailable
        case .biometryNotEnrolled: return .biometryNotEnrolled
        case .biometryLockout: return .biometryLockedOut
        case .passcodeNotSet: return .passcodeNotSet
        default: return .policyUnavailable
        }
    }
}

enum NativeAppLockState: Equatable {
    case unlocked
    case locked
    case unlocking
    case failed(String)
}

@MainActor
final class NativeAppLockCoordinator: ObservableObject {
    @Published private(set) var state: NativeAppLockState
    @Published private(set) var capability: NativeAppLockCapability

    private let authenticator: NativeAppLockAuthenticating
    private var isEnabled: Bool

    init(
        storedPreference: Bool?,
        authenticator: NativeAppLockAuthenticating? = nil
    ) {
        let authenticator = authenticator ?? LocalAuthenticationAppLockAuthenticator()
        self.authenticator = authenticator
        isEnabled = storedPreference == true
        capability = authenticator.capability()
        state = isEnabled ? .locked : .unlocked
    }

    var settingPresentation: NativeAppLockSettingPresentation {
        NativeAppLockSettingPresentation(capability: capability, storedPreference: isEnabled)
    }

    func updatePreference(_ enabled: Bool) {
        guard !enabled || capability.isAvailable else { return }
        isEnabled = enabled
        state = enabled ? .locked : .unlocked
    }

    func refreshCapability() {
        capability = authenticator.capability()
        if isEnabled, state == .unlocked {
            state = .locked
        }
    }

    func lock() {
        guard isEnabled else {
            state = .unlocked
            return
        }
        state = .locked
    }

    func unlockIfNeeded(localizedReason: String = "解锁知乎++") async {
        guard isEnabled else {
            state = .unlocked
            return
        }
        guard state != .unlocking else { return }

        state = .unlocking
        switch await authenticator.authenticate(localizedReason: localizedReason) {
        case .authenticated:
            state = .unlocked
        case let .failed(message):
            state = .failed(message)
        }
    }
}
