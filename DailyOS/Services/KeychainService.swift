import Foundation
import Security

/// Stores sensitive credentials (such as the Gemini API key) securely in the local iOS Keychain
/// without requiring any paid Keychain Sharing entitlements.
enum KeychainService {
    private static let service = "com.patrik.dailyos.credentials"
    private static let geminiAccount = "gemini_api_key"
    private static let offlineFallbackKey = "com.patrik.dailyos.offlineVisionFallback"

    static var offlineVisionFallbackEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: offlineFallbackKey) }
        set { UserDefaults.standard.set(newValue, forKey: offlineFallbackKey) }
    }

    static func saveGeminiAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteGeminiAPIKey()
            return true
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: geminiAccount
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func loadGeminiAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: geminiAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return ""
        }
        return key
    }

    static func deleteGeminiAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: geminiAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var hasGeminiAPIKey: Bool {
        !loadGeminiAPIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
