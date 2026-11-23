import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import Combine

/// Native Google OAuth 2.0 + PKCE authentication using `ASWebAuthenticationSession`
/// (zero external SDKs). Requests `calendar.readonly` and `tasks.readonly` scopes,
/// stores tokens securely in iOS Keychain, and automatically refreshes expired access tokens.
@MainActor
final class GoogleAuthService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleAuthService()

    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let scopes = [
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/tasks.readonly"
    ].joined(separator: " ")

    private static let googleCalSyncKey = "com.patrik.dailyos.googleCalendarSyncEnabled"
    private static let googleTasksSyncKey = "com.patrik.dailyos.googleTasksSyncEnabled"

    @Published var clientID: String = ""
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var isAuthenticating: Bool = false
    @Published var syncGoogleCalendarEnabled: Bool = true
    @Published var syncGoogleTasksEnabled: Bool = true
    @Published var needsWriteScopeReconnect: Bool = false
    @Published var statusMessage: String?

    private var activeAuthSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
        clientID = KeychainService.loadGoogleClientID()
        isConnected = KeychainService.loadGoogleTokens() != nil

        if UserDefaults.standard.object(forKey: Self.googleCalSyncKey) != nil {
            syncGoogleCalendarEnabled = UserDefaults.standard.bool(forKey: Self.googleCalSyncKey)
        }
        if UserDefaults.standard.object(forKey: Self.googleTasksSyncKey) != nil {
            syncGoogleTasksEnabled = UserDefaults.standard.bool(forKey: Self.googleTasksSyncKey)
        }
    }

    func updateClientID(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        clientID = trimmed
        KeychainService.saveGoogleClientID(trimmed)
    }

    func setGoogleCalendarSync(_ enabled: Bool) {
        syncGoogleCalendarEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.googleCalSyncKey)
    }

    func setGoogleTasksSync(_ enabled: Bool) {
        syncGoogleTasksEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.googleTasksSyncKey)
    }

    func signOut() {
        KeychainService.deleteGoogleTokens()
        isConnected = false
        needsWriteScopeReconnect = false
        statusMessage = "Disconnected from Google."
    }

    // MARK: - Reversed Client ID Scheme Calculation

    /// Computes Google's iOS OAuth redirect URI (`com.googleusercontent.apps.<id>:/oauth2redirect/google`)
    /// and callback scheme from the user's iOS OAuth Client ID.
    func reversedClientIDScheme(for rawClientID: String) -> String? {
        let trimmed = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let suffix = ".apps.googleusercontent.com"
        if trimmed.hasSuffix(suffix) {
            let prefix = String(trimmed.dropLast(suffix.count))
            return "com.googleusercontent.apps.\(prefix)"
        }
        // Fallback if user entered only the client prefix
        return "com.googleusercontent.apps.\(trimmed)"
    }

    // MARK: - OAuth 2.0 + PKCE Interactive Sign-In

    func connectGoogle() async {
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, let callbackScheme = reversedClientIDScheme(for: trimmedID) else {
            statusMessage = "Paste your Google OAuth iOS Client ID first."
            return
        }
        KeychainService.saveGoogleClientID(trimmedID)

        let redirectURI = "\(callbackScheme):/oauth2redirect/google"
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let stateToken = UUID().uuidString

        var components = URLComponents(string: Self.authEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: stateToken)
        ]

        guard let authURL = components?.url else {
            statusMessage = "Failed to build Google authorization URL."
            return
        }

        isAuthenticating = true
        statusMessage = "Opening Google sign-in..."

        do {
            let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: callbackScheme
                ) { url, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "GoogleAuth",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "No callback URL returned."]
                        ))
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.activeAuthSession = session
                session.start()
            }

            activeAuthSession = nil

            guard let cbComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let items = cbComponents.queryItems else {
                throw NSError(domain: "GoogleAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid redirect URL."])
            }

            if let oauthError = items.first(where: { $0.name == "error" })?.value {
                throw NSError(domain: "GoogleAuth", code: -3, userInfo: [NSLocalizedDescriptionKey: "Google OAuth error: \(oauthError)"])
            }

            guard let returnedState = items.first(where: { $0.name == "state" })?.value,
                  returnedState == stateToken,
                  let authCode = items.first(where: { $0.name == "code" })?.value else {
                throw NSError(domain: "GoogleAuth", code: -4, userInfo: [NSLocalizedDescriptionKey: "Authorization code or state mismatch."])
            }

            try await exchangeCodeForTokens(
                code: authCode,
                clientID: trimmedID,
                redirectURI: redirectURI,
                codeVerifier: codeVerifier
            )

            isConnected = true
            needsWriteScopeReconnect = false
            isAuthenticating = false
            statusMessage = "Connected to Google Calendar & Tasks."
        } catch {
            activeAuthSession = nil
            isAuthenticating = false
            statusMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Token Exchange & Automatic Refresh

    private func exchangeCodeForTokens(
        code: String,
        clientID: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws {
        let params: [String: String] = [
            "client_id": clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        let tokens = try await postTokenRequest(params: params, fallbackRefreshToken: nil)
        KeychainService.saveGoogleTokens(tokens)
    }

    /// Returns a valid Google OAuth access token, renewing automatically via refresh token if expired.
    func getValidAccessToken() async -> String? {
        guard let existing = KeychainService.loadGoogleTokens() else {
            isConnected = false
            return nil
        }

        // Valid if at least 60 seconds remain before expiry
        if Date().addingTimeInterval(60) < existing.expiresAt {
            return existing.accessToken
        }

        guard let refreshToken = existing.refreshToken, !refreshToken.isEmpty else {
            isConnected = false
            statusMessage = "Google session expired — reconnect in Settings."
            return nil
        }

        let trimmedID = KeychainService.loadGoogleClientID().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return nil }

        do {
            let refreshed = try await postTokenRequest(
                params: [
                    "client_id": trimmedID,
                    "refresh_token": refreshToken,
                    "grant_type": "refresh_token"
                ],
                fallbackRefreshToken: refreshToken
            )
            KeychainService.saveGoogleTokens(refreshed)
            isConnected = true
            return refreshed.accessToken
        } catch {
            statusMessage = "Token refresh failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func postTokenRequest(
        params: [String: String],
        fallbackRefreshToken: String?
    ) async throws -> GoogleOAuthTokens {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw NSError(domain: "GoogleAuth", code: -5, userInfo: [NSLocalizedDescriptionKey: "Invalid token URL."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        var formComponents = URLComponents()
        formComponents.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = formComponents.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errText = String(data: data, encoding: .utf8) ?? "Unknown token error"
            throw NSError(domain: "GoogleAuth", code: -6, userInfo: [NSLocalizedDescriptionKey: String(errText.prefix(160))])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw NSError(domain: "GoogleAuth", code: -7, userInfo: [NSLocalizedDescriptionKey: "Missing access_token in response."])
        }

        let expiresIn = (json["expires_in"] as? Double) ?? 3600.0
        let newRefresh = (json["refresh_token"] as? String) ?? fallbackRefreshToken

        return GoogleOAuthTokens(
            accessToken: accessToken,
            refreshToken: newRefresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
            if let first = scene.windows.first {
                return first
            }
        }
        return ASPresentationAnchor()
    }
}
