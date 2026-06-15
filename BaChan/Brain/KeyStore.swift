import Foundation
import Security

/// Tiny Keychain wrapper for the cloud-provider API keys — generic-password
/// items under one service, one account per provider (`BrainKind.rawValue`).
/// Keys never touch UserDefaults or any JSON file the app writes.
enum KeyStore {
    private static let service = "com.example.BaChan.apikeys"

    private static func query(for account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Save (or replace) a key. An empty value deletes the entry.
    static func save(_ value: String, for account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(account); return }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(for: account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(for: account)
            attributes[kSecValueData as String] = data
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    static func load(_ account: String) -> String? {
        var q = query(for: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    static func delete(_ account: String) {
        SecItemDelete(query(for: account) as CFDictionary)
    }
}
