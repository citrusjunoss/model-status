import Foundation
import Security

enum KeychainStore {
    static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.keychainService,
            kSecAttrAccount as String: AppConfig.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.keychainService,
            kSecAttrAccount as String: AppConfig.keychainAccount
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        addQuery[kSecValueData as String] = data
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.keychainService,
            kSecAttrAccount as String: AppConfig.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
