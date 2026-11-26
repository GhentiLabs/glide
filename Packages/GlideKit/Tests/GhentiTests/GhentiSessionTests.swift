import Foundation
import GlideCore
import Testing
@testable import Ghenti

@Suite struct GhentiSessionTests {
    private func session(_ fake: FakeGhenti) -> GhentiSession {
        GhentiSession(web: fake, http: fake, keychain: Keychain(service: "com.ghentilabs.glide.tests.\(UUID())"))
    }

    @Test func signInUsesPKCEAndRotatesRefreshTokens() async throws {
        let fake = FakeGhenti()
        let session = session(fake)
        let user = try await session.signIn()
        #expect(user == GhentiUser(sub: "user-1", name: "Ada", email: "ada@example.com"))
        #expect(fake.requests[0].url!.path.hasSuffix("/oauth2/token"))
        let form = String(data: fake.bodies[0], encoding: .utf8)!
        #expect(form.contains("resource=https%3A%2F%2Fglide.ghenti.com%2Fv1") || form.contains("resource=https://glide.ghenti.com/v1"))
        #expect(!form.contains("client_secret"))

        #expect(try await session.bearer() == "access-1")
        // Force a refresh: the old refresh token is spent and the new one is kept.
        await session.expireAccessTokenForTesting()
        #expect(try await session.bearer() == "access-2")
        await session.expireAccessTokenForTesting()
        #expect(try await session.bearer() == "access-3")
    }

    @Test func vaultKeyIsAcceptedOnlyForThisPersonAndRequest() async throws {
        let fake = FakeGhenti()
        let session = session(fake)
        try await session.signIn()
        let key = try await session.unlockKey()
        #expect(key == AppKey(key: fake.vaultKey, kid: 1, sub: "user-1"))
        #expect(await session.appKey == key)

        fake.vaultSub = "someone-else"
        await #expect(throws: GhentiError.wrongAccount) { try await session.unlockKey() }

        let good = "key=\(Data(repeating: 1, count: 32).base64URL)&kid=2&sub=u&state=s"
        func parse(_ fragment: String) throws -> AppKey {
            try GhentiSession.appKey(fromCallback: URL(string: "https://glide.ghenti.com/keys/callback#\(fragment)")!, state: "s", sub: "u")
        }
        #expect(try parse(good).kid == 2)
        #expect(throws: GhentiError.stateMismatch) { try parse(good.replacingOccurrences(of: "state=s", with: "state=t")) }
        #expect(throws: GhentiError.badKey) { try parse("key=\(Data(count: 16).base64URL)&kid=2&sub=u&state=s") }
        #expect(throws: GhentiError.badKey) { try parse("key=\(Data(count: 32).base64URL)&kid=0&sub=u&state=s") }
    }

    @Test func aDifferentPersonDoesNotInheritTheKey() async throws {
        let fake = FakeGhenti()
        let session = session(fake)
        try await session.signIn()
        try await session.unlockKey()
        fake.sub = "user-2"
        try await session.signIn()
        #expect(await session.appKey == nil)
    }

    @Test func signOutForgetsTokensAndKey() async throws {
        let fake = FakeGhenti()
        let session = session(fake)
        try await session.signIn()
        try await session.unlockKey()
        await session.signOut()
        let user = await session.user, key = await session.appKey
        #expect(user == nil && key == nil)
        await #expect(throws: GhentiError.signedOut) { try await session.bearer() }
    }
}
