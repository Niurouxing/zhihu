import Foundation
import Security

protocol AccountJSONStore {
    func load() throws -> String?
    func save(_ accountJSON: String) throws
    func clear() throws
    func update(_ transform: (String?) throws -> String?) throws
}

extension AccountJSONStore {
    func update(_ transform: (String?) throws -> String?) throws {
        if let updated = try transform(try load()) {
            try save(updated)
        } else {
            try clear()
        }
    }
}

final class KeychainAccountStore: AccountJSONStore {
    static let defaultService = "com.github.zly2006.zhplus.ios.account"
    static let defaultAccount = "account-json-v1"

    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case invalidUTF8

        var errorDescription: String? {
            switch self {
            case let .keychain(status):
                return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
            case .invalidUTF8:
                return "Stored account data is not valid UTF-8"
            }
        }
    }

    let service: String
    let account: String

    private let lock = NSLock()

    init(
        service: String = KeychainAccountStore.defaultService,
        account: String = KeychainAccountStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> String? {
        try synchronized {
            try loadUnlocked()
        }
    }

    func save(_ accountJSON: String) throws {
        try synchronized {
            try saveUnlocked(accountJSON)
        }
    }

    func clear() throws {
        try synchronized {
            try clearUnlocked()
        }
    }

    func update(_ transform: (String?) throws -> String?) throws {
        try synchronized {
            let current = try loadUnlocked()
            if let updated = try transform(current) {
                try saveUnlocked(updated)
            } else {
                try clearUnlocked()
            }
        }
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func loadUnlocked() throws -> String? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw StoreError.keychain(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidUTF8
        }
        return value
    }

    private func saveUnlocked(_ accountJSON: String) throws {
        let data = Data(accountJSON.utf8)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw StoreError.keychain(updateStatus)
        }

        var item = itemQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StoreError.keychain(addStatus)
        }
    }

    private func clearUnlocked() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
