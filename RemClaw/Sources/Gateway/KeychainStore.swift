import Foundation
import Security

/// Thin wrapper around the Security framework for storing secrets in the iOS Keychain.
/// Mirrors the pattern from OpenClaw's reference iOS app.
enum KeychainStore {
    struct KeychainError: LocalizedError, Equatable {
        let operation: String
        let service: String
        let account: String
        let status: OSStatus

        var errorDescription: String? {
            let systemMessage = SecCopyErrorMessageString(status, nil) as String?
            let detail = systemMessage ?? "OSStatus \(status)"
            return "Keychain \(operation) failed for \(service)/\(account): \(detail)"
        }
    }

    static func loadString(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveString(_ value: String, service: String, account: String) -> Bool {
        do {
            try saveStringOrThrow(value, service: service, account: account)
            return true
        } catch {
            return false
        }
    }

    static func saveStringOrThrow(_ value: String, service: String, account: String) throws {
        try saveDataOrThrow(Data(value.utf8), service: service, account: account)
    }

    static func saveData(_ data: Data, service: String, account: String) -> Bool {
        do {
            try saveDataOrThrow(data, service: service, account: account)
            return true
        } catch {
            return false
        }
    }

    static func saveDataOrThrow(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            guard isRepairableUpdateFailure(status) else {
                throw KeychainError(operation: "update", service: service, account: account, status: status)
            }
            // Simulator reinstalls and debug bundle changes can leave a
            // corrupt or inaccessible row present but not updatable. Because
            // this path already has a fresh replacement value, delete/reinsert
            // only for statuses that identify a stale app-owned item row.
            let deleteStatus = SecItemDelete(query as CFDictionary)
            if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
                throw KeychainError(operation: "repair delete", service: service, account: account, status: deleteStatus)
            }
            try insertData(data, query: query, service: service, account: account)
            return
        }

        try insertData(data, query: query, service: service, account: account)
    }

    private static func insertData(_ data: Data, query: [String: Any], service: String, account: String) throws {
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw KeychainError(operation: "insert", service: service, account: account, status: insertStatus)
        }
    }

    static func isRepairableUpdateFailure(_ status: OSStatus) -> Bool {
        status == errSecDecode || status == errSecInvalidItemRef || status == errSecInteractionNotAllowed
    }

    static func loadData(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    static func delete(service: String, account: String) -> Bool {
        do {
            try deleteOrThrow(service: service, account: account)
            return true
        } catch {
            return false
        }
    }

    static func deleteOrThrow(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "delete", service: service, account: account, status: status)
        }
    }
}
