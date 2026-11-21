import Foundation
import Security

struct GoogleOAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}

/// Stores sensitive credentials (Gemini API Key, Google OAuth Client ID & OAuth Tokens)
/// securely in the local iOS Keychain without paid Keychain Sharing entitlements.
enum KeychainService {
    private static let service = "com.patrik.dailyos.credentials"
    private static let geminiAccount = "gemini_api_key"
    private static let googleClientIDAccount = "google_oauth_client_id"
    private static let googleTokensAccount = "google_oauth_tokens"
    private static let offlineFallbackKey = "com.patrik.dailyos.offlineVisionFallback"

    static var offlineVisionFallbackEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: offlineFallbackKey) }
        set { UserDefaults.standard.set(newValue, forKey: offlineFallbackKey) }
    }

    // MARK: - Generic Keychain Helpers

    @discardableResult
    private static func saveData(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private static func loadData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }

    private static func deleteData(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Gemini API Key

    @discardableResult
    static func saveGeminiAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteGeminiAPIKey()
            return true
        }
        guard let data = trimmed.data(using: .utf8) else { return false }
        return saveData(data, account: geminiAccount)
    }

    static func loadGeminiAPIKey() -> String {
        guard let data = loadData(account: geminiAccount),
              let key = String(data: data, encoding: .utf8) else {
            return ""
        }
        return key
    }

    static func deleteGeminiAPIKey() {
        deleteData(account: geminiAccount)
    }

    static var hasGeminiAPIKey: Bool {
        !loadGeminiAPIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Google OAuth Client ID & Tokens

    @discardableResult
    static func saveGoogleClientID(_ clientID: String) -> Bool {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteData(account: googleClientIDAccount)
            return true
        }
        guard let data = trimmed.data(using: .utf8) else { return false }
        return saveData(data, account: googleClientIDAccount)
    }

    static func loadGoogleClientID() -> String {
        guard let data = loadData(account: googleClientIDAccount),
              let str = String(data: data, encoding: .utf8) else {
            return ""
        }
        return str
    }

    @discardableResult
    static func saveGoogleTokens(_ tokens: GoogleOAuthTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return saveData(data, account: googleTokensAccount)
    }

    static func loadGoogleTokens() -> GoogleOAuthTokens? {
        guard let data = loadData(account: googleTokensAccount) else { return nil }
        return try? JSONDecoder().decode(GoogleOAuthTokens.self, from: data)
    }

    static func deleteGoogleTokens() {
        deleteData(account: googleTokensAccount)
    }
}
