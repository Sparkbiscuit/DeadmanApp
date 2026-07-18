import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit

// MARK: - Tokens

/// The Google OAuth credential set, stored as one Keychain item.
struct GoogleTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// From the id_token, for the Settings "connected as" line.
    var email: String?

    /// Whether the access token is still comfortably usable (a minute of
    /// slack so a token can't expire mid-request).
    func isFresh(at date: Date = Date()) -> Bool {
        expiresAt > date.addingTimeInterval(60)
    }
}

enum GoogleAuthError: Error {
    case cancelled
    case invalidCallback
    case tokenEndpointFailed
    case notConnected
    /// The refresh token was revoked or expired — the user must reconnect.
    case needsReconnect
    case keychain(OSStatus)
}

// MARK: - Keychain store

/// Generic-password Keychain storage for the Google tokens. Deliberately a
/// tiny standalone wrapper — the shared pattern for any future OAuth
/// integration.
enum GoogleTokenStore {
    private static let service = "com.christoforakis.Filuma.google"
    private static let account = "oauth"

    static func load() -> GoogleTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(GoogleTokens.self, from: data)
    }

    static func save(_ tokens: GoogleTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw GoogleAuthError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw GoogleAuthError.keychain(status)
        }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

// MARK: - OAuth client

/// PKCE authorization-code flow against Google, with no SDK and no backend:
/// `ASWebAuthenticationSession` carries the consent screen, URLSession does
/// the token exchange and refresh, and the tokens live in the Keychain.
@MainActor
final class GoogleOAuth: NSObject {
    static let shared = GoogleOAuth()

    static let clientId = "720600189786-8m8c9bqvpipununa0vh9u03binokuhtv.apps.googleusercontent.com"
    /// The reversed client ID — registered as a URL scheme in Info.plist and
    /// used as the OAuth redirect.
    static let redirectScheme = "com.googleusercontent.apps.720600189786-8m8c9bqvpipununa0vh9u03binokuhtv"
    static var redirectURI: String { redirectScheme + ":/oauth2redirect" }
    /// calendar.events per the integration plan; openid+email only so
    /// Settings can show which account is connected.
    static let scopes = "https://www.googleapis.com/auth/calendar.events openid email"

    private static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Kept alive for the duration of the browser round trip.
    private var webSession: ASWebAuthenticationSession?
    /// Actor reentrancy means every waiter must share the refresh already in
    /// flight instead of observing the same stale Keychain value and starting
    /// another token request.
    private static var refreshTask: (id: UUID, task: Task<GoogleTokens, Error>)?

    // MARK: Connect

    /// The full round trip: consent in the browser → authorization code →
    /// tokens saved to the Keychain.
    func connect() async throws -> GoogleTokens {
        let verifier = Self.randomURLSafeString(byteCount: 48)
        var components = URLComponents(url: Self.authEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Native clients get refresh tokens by default, but asking
            // explicitly costs nothing and exchangeCode requires one.
            URLQueryItem(name: "access_type", value: "offline")
        ]

        let code = try await authorizationCode(authURL: components.url!)
        let tokens = try await Self.exchangeCode(code, verifier: verifier)
        try GoogleTokenStore.save(tokens)
        return tokens
    }

    static func disconnect() {
        refreshTask?.task.cancel()
        refreshTask = nil
        GoogleTokenStore.clear()
    }

    private func authorizationCode(authURL: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: Self.redirectScheme
            ) { callbackURL, error in
                if let callbackURL,
                   let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                       .queryItems?.first(where: { $0.name == "code" })?.value {
                    continuation.resume(returning: code)
                } else if let error, (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: GoogleAuthError.cancelled)
                } else {
                    continuation.resume(throwing: GoogleAuthError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            self.webSession = session
            if !session.start() {
                continuation.resume(throwing: GoogleAuthError.invalidCallback)
            }
        }
    }

    // MARK: Token endpoint

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Double
        let refreshToken: String?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    static func exchangeCode(
        _ code: String,
        verifier: String,
        urlSession: URLSession = .shared
    ) async throws -> GoogleTokens {
        let response = try await tokenRequest(
            parameters: [
                "client_id": clientId,
                "code": code,
                "code_verifier": verifier,
                "grant_type": "authorization_code",
                "redirect_uri": redirectURI
            ],
            urlSession: urlSession
        )
        guard let refreshToken = response.refreshToken else {
            throw GoogleAuthError.tokenEndpointFailed
        }
        return GoogleTokens(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn),
            email: response.idToken.flatMap(parseEmail(fromIdToken:))
        )
    }

    static func refresh(
        _ tokens: GoogleTokens,
        urlSession: URLSession = .shared
    ) async throws -> GoogleTokens {
        let response = try await tokenRequest(
            parameters: [
                "client_id": clientId,
                "refresh_token": tokens.refreshToken,
                "grant_type": "refresh_token"
            ],
            urlSession: urlSession
        )
        var refreshed = tokens
        refreshed.accessToken = response.accessToken
        refreshed.expiresAt = Date().addingTimeInterval(response.expiresIn)
        return refreshed
    }

    /// A usable access token, refreshing through the Keychain when stale.
    /// Throws `.needsReconnect` when the refresh token itself is dead.
    static func validAccessToken(urlSession: URLSession = .shared) async throws -> String {
        guard let tokens = GoogleTokenStore.load() else {
            throw GoogleAuthError.notConnected
        }
        if tokens.isFresh() {
            return tokens.accessToken
        }
        return try await refreshAccessToken(tokens, urlSession: urlSession)
    }

    /// Refresh after an API rejects a token. If another request already
    /// replaced that exact token, use its result instead of refreshing again.
    static func refreshAccessToken(
        rejectedAccessToken: String,
        urlSession: URLSession = .shared
    ) async throws -> String {
        guard let tokens = GoogleTokenStore.load() else {
            throw GoogleAuthError.notConnected
        }
        if tokens.accessToken != rejectedAccessToken, tokens.isFresh() {
            return tokens.accessToken
        }
        return try await refreshAccessToken(tokens, urlSession: urlSession)
    }

    private static func refreshAccessToken(
        _ tokens: GoogleTokens,
        urlSession: URLSession
    ) async throws -> String {
        if let refreshTask {
            return try await refreshTask.task.value.accessToken
        }

        let id = UUID()
        let task = Task {
            let refreshed = try await refresh(tokens, urlSession: urlSession)
            try Task.checkCancellation()
            try GoogleTokenStore.save(refreshed)
            return refreshed
        }
        refreshTask = (id, task)

        do {
            let refreshed = try await task.value
            if refreshTask?.id == id { refreshTask = nil }
            return refreshed.accessToken
        } catch {
            if refreshTask?.id == id { refreshTask = nil }
            throw error
        }
    }

    private static func tokenRequest(
        parameters: [String: String],
        urlSession: URLSession
    ) async throws -> TokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleAuthError.tokenEndpointFailed
        }
        guard http.statusCode == 200 else {
            // invalid_grant means the refresh token is revoked/expired — the
            // one failure that needs the user, not a retry.
            if let body = String(data: data, encoding: .utf8), body.contains("invalid_grant") {
                throw GoogleAuthError.needsReconnect
            }
            throw GoogleAuthError.tokenEndpointFailed
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: PKCE + id_token helpers (pure, unit-tested)

    nonisolated static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    /// RFC 7636 S256: BASE64URL(SHA256(ASCII(verifier))).
    nonisolated static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Pulls the email claim out of an id_token without verifying it — it
    /// arrived over TLS from Google's token endpoint and is display-only.
    nonisolated static func parseEmail(fromIdToken idToken: String) -> String? {
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return claims["email"] as? String
    }

    nonisolated private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Presentation anchor

extension GoogleOAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}
