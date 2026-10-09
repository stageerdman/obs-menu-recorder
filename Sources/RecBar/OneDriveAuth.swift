import Foundation
import CryptoKit
import AppKit

/// Hand-rolled OAuth2 **authorization-code flow with PKCE** against Microsoft's `consumers`
/// tenant (personal Microsoft accounts specifically — see CLAUDE.md). No MSAL/third-party
/// dependency, matching OBSClient.swift's own hand-rolled-protocol precedent.
///
/// The interactive sign-in (modelled on the Pensieve project) opens the user's real browser to
/// the Microsoft consent screen and catches the redirect on a one-shot loopback HTTP server
/// (`LoopbackOAuthServer`) — no code to copy by hand, no modal "enter this code" sheet. This is
/// a *public* client (no client secret, same as the old device-code design), so PKCE is what
/// proves the token request came from the same app that started the sign-in.
///
/// Only the refresh token is persisted (Keychain); the access token lives in memory only and is
/// re-minted on demand.
@MainActor
final class OneDriveAuth {
    enum AuthError: Error, LocalizedError {
        case missingClientId
        case signInFailed(String)
        case stateMismatch
        case declined
        case cancelled
        case notSignedIn
        case refreshFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingClientId: return "Set oneDrive.clientId in config.json first."
            case .signInFailed(let m): return "OneDrive sign-in failed: \(m)"
            case .stateMismatch: return "OneDrive sign-in couldn't be verified — please try again."
            case .declined: return "OneDrive sign-in was declined."
            case .cancelled: return "OneDrive sign-in was cancelled."
            case .notSignedIn: return "Not signed in to OneDrive."
            case .refreshFailed(let m): return "Couldn't reach OneDrive to refresh sign-in (still signed in — just retry): \(m)"
            }
        }
    }

    /// Set once by `LibraryViewModel` from `RecBarConfig.oneDrive.clientId` — kept here rather
    /// than threaded through every method call, since there's only ever one configured account.
    var clientId: String = ""

    private static let tenant = "consumers"
    private static let scope = "Files.ReadWrite offline_access"
    private static let refreshTokenAccount = "refreshToken"

    private var accessToken: String?
    private var accessTokenExpiry: Date?
    /// The loopback listener for an in-flight interactive sign-in, so a UI "Cancel" can tear it
    /// down and unblock `signInInteractive`'s awaited redirect.
    private var activeServer: LoopbackOAuthServer?

    var isSignedIn: Bool {
        KeychainHelper.load(account: Self.refreshTokenAccount) != nil
    }

    func signOut() {
        accessToken = nil
        accessTokenExpiry = nil
        KeychainHelper.delete(account: Self.refreshTokenAccount)
    }

    /// Runs the full interactive sign-in: spins up a loopback redirect catcher, opens the
    /// system browser to the Microsoft consent screen, waits for the redirect, and exchanges
    /// the returned authorization code (with the PKCE verifier) for tokens — storing the
    /// refresh token on success. Resolves when the user has signed in, throws if they decline,
    /// close the browser without finishing (timeout), or the exchange fails.
    func signInInteractive(timeout: TimeInterval = 300) async throws {
        guard !clientId.isEmpty else { throw AuthError.missingClientId }

        let (verifier, challenge) = Self.makePKCE()
        let state = Self.randomURLSafe(32)

        // Bind the loopback listener BEFORE opening the browser so the redirect is never missed.
        let server = LoopbackOAuthServer()
        activeServer = server
        defer { activeServer = nil }
        let port: UInt16
        do {
            port = try await server.start()
        } catch {
            throw AuthError.signInFailed(error.localizedDescription)
        }
        let redirectURI = "http://localhost:\(port)/callback"

        openConsentPage(redirectURI: redirectURI, state: state, challenge: challenge)

        let redirect: LoopbackOAuthServer.Redirect
        do {
            redirect = try await server.waitForRedirect(timeout: timeout)
        } catch LoopbackOAuthServer.ServerError.cancelled {
            throw AuthError.cancelled
        } catch {
            throw AuthError.signInFailed(error.localizedDescription)
        }

        if let error = redirect.error {
            throw error == "access_denied" ? AuthError.declined : AuthError.signInFailed(error)
        }
        guard redirect.state == state else { throw AuthError.stateMismatch }
        guard let code = redirect.code else { throw AuthError.signInFailed("no authorization code returned") }

        try await exchangeCode(code, verifier: verifier, redirectURI: redirectURI)
    }

    /// Tears down an in-flight interactive sign-in (from a UI "Cancel"), causing
    /// `signInInteractive` to throw `AuthError.cancelled`. No-op if nothing is in flight.
    func cancelInteractiveSignIn() {
        activeServer?.cancel()
    }

    private func openConsentPage(redirectURI: String, state: String, challenge: String) {
        var components = URLComponents(string: "https://login.microsoftonline.com/\(Self.tenant)/oauth2/v2.0/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Always show the account chooser so the user can pick which OneDrive to use.
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws {
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(Self.tenant)/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": clientId,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "scope": Self.scope,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json else {
            let message = json?["error_description"] as? String
                ?? json?["error"] as? String
                ?? String(data: data, encoding: .utf8)
                ?? "unknown error"
            throw AuthError.signInFailed(message.split(separator: "\n").first.map(String.init) ?? message)
        }
        try storeTokens(from: json)
    }

    // MARK: - PKCE

    /// Returns a `(verifier, challenge)` pair for the PKCE S256 method: the verifier is a random
    /// URL-safe string kept in memory, the challenge is its base64url-encoded SHA256 digest sent
    /// with the authorize request. Proving possession of the verifier at the token exchange is
    /// what lets this be a public client with no client secret.
    private static func makePKCE() -> (verifier: String, challenge: String) {
        let verifier = randomURLSafe(32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return (verifier, base64URL(Data(digest)))
    }

    private static func randomURLSafe(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Returns a currently-valid access token, silently refreshing via the stored refresh
    /// token if the cached one is missing or near expiry.
    func validAccessToken() async throws -> String {
        if let accessToken, let expiry = accessTokenExpiry, expiry > Date().addingTimeInterval(60) {
            return accessToken
        }
        guard !clientId.isEmpty else { throw AuthError.missingClientId }
        guard let refreshTokenData = KeychainHelper.load(account: Self.refreshTokenAccount),
              let refreshToken = String(data: refreshTokenData, encoding: .utf8) else {
            throw AuthError.notSignedIn
        }

        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(Self.tenant)/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": Self.scope
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if status == 200, let json {
            try storeTokens(from: json)
            guard let accessToken else { throw AuthError.notSignedIn }
            return accessToken
        }

        // Only discard the saved sign-in when Microsoft explicitly says the refresh token
        // itself is no longer usable — `invalid_grant` (revoked, aged out past its lifetime,
        // consent removed) or `interaction_required` (the user genuinely must re-auth). These
        // are the only cases where a fresh device-code sign-in is the actual remedy.
        //
        // Everything else — a 5xx, throttling (429), or a malformed/empty body from a flaky
        // connection — is transient: keep the refresh token so the *next* retry silently
        // reuses it instead of forcing another full sign-in. This is the whole reason sign-in
        // used to be demanded "constantly": the old code called signOut() on ANY non-200, so a
        // single network blip during a token refresh permanently wiped a working sign-in.
        let errorCode = json?["error"] as? String
        let mustReauth = errorCode == "invalid_grant" || errorCode == "interaction_required"
        if mustReauth {
            signOut()
            throw AuthError.notSignedIn
        }
        throw AuthError.refreshFailed(
            json?["error_description"] as? String ?? errorCode ?? "HTTP \(status)")
    }

    private func storeTokens(from json: [String: Any]) throws {
        guard let token = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw AuthError.signInFailed("token response missing access_token")
        }
        accessToken = token
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        if let refresh = json["refresh_token"] as? String, let data = refresh.data(using: .utf8) {
            KeychainHelper.save(data, account: Self.refreshTokenAccount)
        }
    }

    private func formBody(_ params: [String: String]) -> Data {
        params.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&").data(using: .utf8)!
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=")
        return set
    }()
}
