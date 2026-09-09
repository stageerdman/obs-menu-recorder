import Foundation

/// One step of Microsoft's OAuth2 device-code flow — shown to the user as a code to enter at
/// `verificationUri` in their own browser, since this menu-bar app has no embedded webview
/// and no registered custom URL scheme for an interactive auth-code redirect.
struct DeviceCodeResponse: Codable, Identifiable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int

    var id: String { deviceCode }

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

/// Hand-rolled OAuth2 device-code flow against Microsoft's `consumers` tenant (personal
/// Microsoft accounts specifically — see CLAUDE.md). No MSAL/third-party dependency, matching
/// OBSClient.swift's own hand-rolled-protocol precedent. Only the refresh token is persisted
/// (Keychain); the access token lives in memory only and is re-minted on demand.
@MainActor
final class OneDriveAuth {
    enum AuthError: Error, LocalizedError {
        case missingClientId
        case deviceCodeFailed(String)
        case pollFailed(String)
        case expired
        case declined
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .missingClientId: return "Set oneDrive.clientId in config.json first."
            case .deviceCodeFailed(let m): return "Could not start OneDrive sign-in: \(m)"
            case .pollFailed(let m): return "OneDrive sign-in failed: \(m)"
            case .expired: return "OneDrive sign-in code expired — try again."
            case .declined: return "OneDrive sign-in was declined."
            case .notSignedIn: return "Not signed in to OneDrive."
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

    var isSignedIn: Bool {
        KeychainHelper.load(account: Self.refreshTokenAccount) != nil
    }

    func signOut() {
        accessToken = nil
        accessTokenExpiry = nil
        KeychainHelper.delete(account: Self.refreshTokenAccount)
    }

    func requestDeviceCode() async throws -> DeviceCodeResponse {
        guard !clientId.isEmpty else { throw AuthError.missingClientId }
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(Self.tenant)/oauth2/v2.0/devicecode")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["client_id": clientId, "scope": Self.scope])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.deviceCodeFailed(String(data: data, encoding: .utf8) ?? "unknown error")
        }
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    /// Polls until the user completes sign-in in their browser, or the code expires.
    func pollForToken(_ device: DeviceCodeResponse) async throws {
        var interval = max(device.interval, 5)
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

            var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/\(Self.tenant)/oauth2/v2.0/token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody([
                "client_id": clientId,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": device.deviceCode
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            if (response as? HTTPURLResponse)?.statusCode == 200, let json {
                try storeTokens(from: json)
                return
            }

            switch json?["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
                continue
            case "expired_token":
                throw AuthError.expired
            case "authorization_declined":
                throw AuthError.declined
            default:
                throw AuthError.pollFailed(json?["error_description"] as? String ?? "unknown error")
            }
        }
        throw AuthError.expired
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
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            signOut() // refresh token revoked/expired — force a fresh sign-in next time
            throw AuthError.notSignedIn
        }
        try storeTokens(from: json)
        guard let accessToken else { throw AuthError.notSignedIn }
        return accessToken
    }

    private func storeTokens(from json: [String: Any]) throws {
        guard let token = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw AuthError.pollFailed("token response missing access_token")
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
