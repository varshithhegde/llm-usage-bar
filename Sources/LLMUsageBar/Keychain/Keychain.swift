import Foundation
import Security

enum Keychain {
    static let service = "dev.varshith.LLMUsageBar"
    static let account = "litellm-api-key"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    static func save(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return delete() }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "LLM Usage Bar – LiteLLM API key"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let s = SecItemDelete(baseQuery() as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }

    /// Keychain first, then the LITELLM_API_KEY environment variable.
    static func resolvedKey() -> (key: String, fromEnv: Bool)? {
        if let k = read() { return (k, false) }
        if let e = ProcessInfo.processInfo.environment["LITELLM_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty {
            return (e, true)
        }
        return nil
    }
}
