import CryptoKit
import Foundation
import GlideCore

/// Where Glide talks to Ghenti. Glide is the public native client "glide" of auth.ghenti.com.
public struct GhentiConfig: Sendable {
    public var issuer = URL(string: "https://auth.ghenti.com/api/auth")!
    public var vault = URL(string: "https://auth.ghenti.com/vault")!
    public var clientID = "glide"
    /// Callbacks land on this host, which only Glide can claim through Apple associated domains.
    public var callbackHost = "glide.ghenti.com"
    public var api = URL(string: "https://glide.ghenti.com/v1")!
    public var scope = "openid profile email offline_access"

    public static let production = GhentiConfig()
    public init() {}

    var redirectURI: String { "https://\(callbackHost)/auth/callback" }
    var resource: String { api.absoluteString }
    func endpoint(_ path: String) -> URL { issuer.appendingPathComponent(path) }
}

/// Opens a sign-in page and returns the URL it finished on. ASWebAuthenticationSession in the app; a script in tests.
public protocol WebAuthenticator: Sendable {
    func authenticate(_ url: URL, callbackHost: String, callbackPath: String) async throws -> URL
}

/// Sends a request. URLSession in the app; a fake server in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// The signed-in person, from the ID token.
public struct GhentiUser: Codable, Sendable, Equatable {
    public var sub: String
    public var name: String?
    public var email: String?
}

/// Glide's key from the Ghenti vault, for one key generation of one user.
public struct AppKey: Codable, Sendable, Equatable {
    public var key: Data
    public var kid: Int
    public var sub: String
}

public enum GhentiError: Error, Equatable {
    case cancelled
    case stateMismatch
    case denied(String)
    case badResponse(Int)
    case wrongAccount
    case badKey
    case signedOut
}

/// Sign-in, tokens and the vault key. Tokens and the key live in the keychain; the access token only in memory.
public actor GhentiSession {
    public nonisolated let config: GhentiConfig
    private let web: any WebAuthenticator
    private let http: any HTTPTransport
    private let keychain: Keychain
    private var accessToken: (value: String, expires: Date)?

    public init(config: GhentiConfig = .production, web: any WebAuthenticator, http: any HTTPTransport = URLSession.shared,
                keychain: Keychain = Keychain(service: "com.ghentilabs.glide.ghenti")) {
        self.config = config
        self.web = web
        self.http = http
        self.keychain = keychain
    }

    public var user: GhentiUser? { keychain.value(GhentiUser.self, "user") }
    public var appKey: AppKey? { keychain.value(AppKey.self, "appKey") }

    // MARK: Sign-in

    /// OAuth 2.1 authorization code with PKCE, asking for a JWT access token for Glide's API.
    @discardableResult
    public func signIn() async throws -> GhentiUser {
        let verifier = Self.random(32)
        let state = Self.random(24)
        var authorize = URLComponents(url: config.endpoint("oauth2/authorize"), resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI), .init(name: "scope", value: config.scope),
            .init(name: "state", value: state), .init(name: "code_challenge", value: Self.challenge(verifier)),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "resource", value: config.resource),
        ]
        let callback = try await web.authenticate(authorize.url!, callbackHost: config.callbackHost, callbackPath: "/auth/callback")
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard item("state") == state else { throw GhentiError.stateMismatch }
        if let error = item("error") { throw error == "access_denied" ? GhentiError.cancelled : GhentiError.denied(error) }
        guard let code = item("code") else { throw GhentiError.denied("no_code") }

        let tokens = try await token([
            "grant_type": "authorization_code", "code": code, "redirect_uri": config.redirectURI,
            "client_id": config.clientID, "code_verifier": verifier, "resource": config.resource,
        ])
        guard let idToken = tokens.id_token, let user = Self.user(fromIDToken: idToken) else { throw GhentiError.badResponse(200) }
        // A different person signing in on this Mac must not inherit the last one's key.
        if let previous = self.user, previous.sub != user.sub { keychain.remove("appKey") }
        keychain.set(value: user, "user")
        return user
    }

    /// A valid access token, refreshed when it has under a minute left. Refresh tokens rotate on every use.
    public func bearer() async throws -> String {
        if let accessToken, accessToken.expires.timeIntervalSinceNow > 60 { return accessToken.value }
        guard let refresh = keychain.data("refresh").flatMap({ String(data: $0, encoding: .utf8) }) else { throw GhentiError.signedOut }
        do {
            _ = try await token([
                "grant_type": "refresh_token", "refresh_token": refresh, "client_id": config.clientID, "resource": config.resource,
            ])
        } catch GhentiError.badResponse(let status) where status == 400 || status == 401 {
            // The refresh token was revoked or expired: the person has to sign in again.
            signOutLocally()
            throw GhentiError.signedOut
        }
        guard let accessToken else { throw GhentiError.signedOut }
        return accessToken.value
    }

    public func signOut() async {
        if let refresh = keychain.data("refresh").flatMap({ String(data: $0, encoding: .utf8) }) {
            var request = Self.form(config.endpoint("oauth2/revoke"), ["token": refresh, "token_type_hint": "refresh_token", "client_id": config.clientID])
            request.timeoutInterval = 5
            _ = try? await http.send(request)
        }
        signOutLocally()
    }

    /// Tests force the next `bearer()` to refresh.
    func expireAccessTokenForTesting() { accessToken = nil }

    private func signOutLocally() {
        accessToken = nil
        for account in ["refresh", "user", "appKey"] { keychain.remove(account) }
    }

    private struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Double?
    }

    private func token(_ fields: [String: String]) async throws -> Tokens {
        let (data, response) = try await http.send(Self.form(config.endpoint("oauth2/token"), fields))
        guard response.statusCode == 200 else { throw GhentiError.badResponse(response.statusCode) }
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        accessToken = (tokens.access_token, Date().addingTimeInterval(tokens.expires_in ?? 3600))
        if let refresh = tokens.refresh_token { keychain.set(Data(refresh.utf8), "refresh") }
        return tokens
    }

    // MARK: Vault key

    /// Opens the Ghenti vault, which unlocks with a passkey, recovery code or another device and hands Glide its key.
    @discardableResult
    public func unlockKey() async throws -> AppKey {
        guard let user else { throw GhentiError.signedOut }
        let state = Self.random(24)
        var vault = URLComponents(url: config.vault, resolvingAgainstBaseURL: false)!
        vault.queryItems = [.init(name: "client_id", value: config.clientID), .init(name: "state", value: state)]
        let callback = try await web.authenticate(vault.url!, callbackHost: config.callbackHost, callbackPath: "/keys/callback")
        let key = try Self.appKey(fromCallback: callback, state: state, sub: user.sub)
        keychain.set(value: key, "appKey")
        return key
    }

    /// The vault returns `#key=…&kid=…&sub=…&state=…`. Accept it only for this request and this person, and only a 32-byte key.
    static func appKey(fromCallback url: URL, state: String, sub: String) throws -> AppKey {
        var parts = URLComponents()
        parts.percentEncodedQuery = url.fragment
        let items = parts.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard item("state") == state else { throw GhentiError.stateMismatch }
        if let error = item("error") { throw GhentiError.denied(error) }
        guard item("sub") == sub else { throw GhentiError.wrongAccount }
        guard let kid = item("kid").flatMap(Int.init), kid >= 1,
            let key = item("key").flatMap(Data.init(base64URL:)), key.count == 32
        else { throw GhentiError.badKey }
        return AppKey(key: key, kid: kid, sub: sub)
    }

    // MARK: Helpers

    static func user(fromIDToken token: String) -> GhentiUser? {
        // Read, not verified: it came straight from the token endpoint over TLS (OIDC Core 3.1.3.7).
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = Data(base64URL: String(parts[1])),
            let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let sub = claims["sub"] as? String
        else { return nil }
        return GhentiUser(sub: sub, name: claims["name"] as? String, email: claims["email"] as? String)
    }

    static func random(_ bytes: Int) -> String {
        SymmetricKey(size: SymmetricKeySize(bitCount: bytes * 8)).withUnsafeBytes { Data($0) }.base64URL
    }

    static func challenge(_ verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }

    static func form(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" alone, which a form body reads as a space.
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return request
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }
}
