import AppKit
import Foundation

enum AuthError: LocalizedError, Equatable {
    case noClientID
    case signedOut
    case revoked
    case stateMismatch
    case denied(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .noClientID: return "No Reddit client ID is configured. Add one in Settings → Account."
        case .signedOut: return "Not signed in to Reddit."
        case .revoked: return "Reddit no longer accepts this sign-in (it was revoked or expired). Sign in again."
        case .stateMismatch: return "The sign-in response didn't match this request. Try again."
        case .denied(let m): return "Reddit returned: \(m)"
        case .server(let m): return m
        }
    }
}

/// Low-level OAuth2 calls against reddit.com (token endpoint), shared by sign-in and refresh.
enum RedditAuth {
    static let authorizeURL = URL(string: "https://www.reddit.com/api/v1/authorize")!
    static let tokenURL = URL(string: "https://www.reddit.com/api/v1/access_token")!
    static let revokeURL = URL(string: "https://www.reddit.com/api/v1/revoke_token")!
    static let redirectURI = "krma://oauth"
    static let scopes = "identity mysubreddits"

    /// The maintainer's "installed app" from reddit.com/prefs/apps. Public, like an OAuth client
    /// ID always is; installed apps get no secret. Empty until the app is registered.
    static let defaultClientID = ""

    static var clientID: String {
        let custom = UserDefaults.standard.string(forKey: SettingsKey.redditClientID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? defaultClientID : custom
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Reddit asks for `platform:app id:version (by /u/username)`; unidentified clients get throttled.
    static func userAgent(user: String?) -> String {
        "macos:io.github.mrte1122.Krma:v\(appVersion)" + (user.map { " (by /u/\($0))" } ?? "")
    }

    struct TokenResponse: Decodable {
        let access_token: String?
        let token_type: String?
        let expires_in: Int?
        let scope: String?
        let refresh_token: String?
        let error: String?
    }

    static func exchange(code: String) async throws -> TokenResponse {
        try await post(["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI])
    }

    static func refresh(refreshToken: String) async throws -> TokenResponse {
        try await post(["grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    /// Best effort; a failure here only means the authorization lingers on reddit.com.
    static func revoke(refreshToken: String) async {
        _ = try? await post(["token": refreshToken, "token_type_hint": "refresh_token"], url: revokeURL)
    }

    private static func post(_ form: [String: String], url: URL = tokenURL) async throws -> TokenResponse {
        let id = clientID
        guard !id.isEmpty else { throw AuthError.noClientID }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Installed apps authenticate with the client ID and an empty password.
        req.setValue("Basic " + Data("\(id):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent(user: nil), forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+:/ ")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if url == revokeURL { return TokenResponse(access_token: nil, token_type: nil, expires_in: nil, scope: nil, refresh_token: nil, error: nil) }
        guard let r = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.server("Reddit returned HTTP \(code) with an unexpected body.")
        }
        if let e = r.error {
            if e == "invalid_grant" { throw AuthError.revoked }
            if code == 401 { throw AuthError.denied("the client ID was rejected (401). Check it in Settings → Account.") }
            throw AuthError.denied(e)
        }
        guard r.access_token != nil else { throw AuthError.server("Reddit returned HTTP \(code) without a token.") }
        return r
    }
}

/// Hands out a valid access token, refreshing it when needed. Serialized so two callers hitting
/// an expired token don't both refresh.
actor TokenVault {
    private var cached: (token: String, expires: Date)?

    nonisolated var isSignedIn: Bool { Keychain.load(.refreshToken) != nil }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh {
            if let c = cached, c.expires.timeIntervalSinceNow > 60 { return c.token }
            if let t = Keychain.load(.accessToken),
               let exp = UserDefaults.standard.object(forKey: SettingsKey.accessTokenExpiry) as? Date,
               exp.timeIntervalSinceNow > 60 {
                cached = (t, exp)
                return t
            }
        }
        guard let refresh = Keychain.load(.refreshToken) else { throw AuthError.signedOut }
        let r = try await RedditAuth.refresh(refreshToken: refresh)
        guard let token = r.access_token else { throw AuthError.server("Reddit returned no access token.") }
        store(token: token, expiresIn: r.expires_in ?? 3600)
        return token
    }

    func store(token: String, expiresIn: Int) {
        let exp = Date().addingTimeInterval(TimeInterval(expiresIn))
        Keychain.save(token, .accessToken)
        UserDefaults.standard.set(exp, forKey: SettingsKey.accessTokenExpiry)
        cached = (token, exp)
    }

    func clear() {
        cached = nil
        Keychain.delete(.accessToken)
        Keychain.delete(.refreshToken)
        UserDefaults.standard.removeObject(forKey: SettingsKey.accessTokenExpiry)
    }
}

/// "Sign in with Reddit": opens the authorization page in the browser and finishes when Reddit
/// redirects to `krma://oauth` (or when the redirect URL is pasted in).
@MainActor
final class RedditSignIn: ObservableObject {
    enum State: Equatable {
        case idle
        case waiting(URL)
        case exchanging
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isSignedIn = Keychain.load(.refreshToken) != nil
    var onSignedIn: (() -> Void)?
    var onSignedOut: (() -> Void)?
    let vault: TokenVault
    private var pendingState: String?

    init(vault: TokenVault) { self.vault = vault }

    var hasClientID: Bool { !RedditAuth.clientID.isEmpty }

    var isBusy: Bool {
        switch state {
        case .waiting, .exchanging: return true
        default: return false
        }
    }

    func authorizationURL(state: String) -> URL {
        var comps = URLComponents(url: RedditAuth.authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: RedditAuth.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "state", value: state),
            .init(name: "redirect_uri", value: RedditAuth.redirectURI),
            .init(name: "duration", value: "permanent"),
            .init(name: "scope", value: RedditAuth.scopes),
        ]
        return comps.url!
    }

    func start(openBrowser: Bool = true) {
        guard hasClientID else { state = .failed(AuthError.noClientID.localizedDescription); return }
        if RedditAuth.clientID.count < 10 {
            state = .failed("The client ID \"\(RedditAuth.clientID)\" is too short. Reddit shows its \"you broke reddit\" page for unknown client IDs; paste the full ID from reddit.com/prefs/apps.")
            return
        }
        let s = UUID().uuidString
        pendingState = s
        let url = authorizationURL(state: s)
        state = .waiting(url)
        if openBrowser { NSWorkspace.shared.open(url) }
    }

    func cancel() {
        pendingState = nil
        state = .idle
    }

    /// Handles `krma://oauth?code=…&state=…`. Returns false for URLs that aren't ours.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "krma" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let e = q("error") {
            state = .failed(e == "access_denied" ? "Sign-in was declined on Reddit." : "Reddit returned: \(e)")
            pendingState = nil
            return true
        }
        guard let code = q("code"), !code.isEmpty else {
            state = .failed("Reddit didn't send a sign-in code.")
            return true
        }
        // A pasted URL may belong to a request started before the app was relaunched; accept it
        // only when we have no pending state to compare against (the code itself is single-use).
        if let expected = pendingState, q("state") != expected {
            state = .failed(AuthError.stateMismatch.localizedDescription)
            return true
        }
        pendingState = nil
        state = .exchanging
        Task { await exchange(code: code) }
        return true
    }

    /// The fallback for a browser that didn't bounce back: the user pastes the address bar.
    func handlePasted(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), handle(url: url) else {
            state = .failed("That doesn't look like the krma://oauth?… address Reddit redirected to.")
            return
        }
    }

    private func exchange(code: String) async {
        do {
            let r = try await RedditAuth.exchange(code: code)
            guard let access = r.access_token, let refresh = r.refresh_token else {
                throw AuthError.server("Reddit didn't return a permanent sign-in. Make sure the app's redirect URI is exactly \(RedditAuth.redirectURI).")
            }
            Keychain.save(refresh, .refreshToken)
            await vault.store(token: access, expiresIn: r.expires_in ?? 3600)
            isSignedIn = true
            state = .idle
            onSignedIn?()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Forgets the tokens on this Mac and asks Reddit to revoke them.
    func signOut() {
        cancel()
        let refresh = Keychain.load(.refreshToken)
        Task {
            if let refresh { await RedditAuth.revoke(refreshToken: refresh) }
            await vault.clear()
            isSignedIn = false
            onSignedOut?()
        }
    }

    /// Called by the store when a refresh fails with invalid_grant.
    func markRevoked() {
        Task {
            await vault.clear()
            isSignedIn = false
        }
    }
}
