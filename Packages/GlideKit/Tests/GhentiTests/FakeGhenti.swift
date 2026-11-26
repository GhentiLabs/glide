import CryptoKit
import Foundation
@testable import Ghenti

/// Auth and the Glide API as seen over the network: just enough of each to drive real sign-in and sync code.
final class FakeGhenti: HTTPTransport, WebAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    var requests: [URLRequest] = []
    var bodies: [Data] = []
    // Auth
    var sub = "user-1"
    var issuedRefresh = 0
    var lastChallenge: String?
    var vaultKey = Data(repeating: 9, count: 32)
    var vaultKid = 1
    var vaultSub: String?
    // API
    var records: [UUID: GlideAPI.Record] = [:]
    var audio: [UUID: Data] = [:]
    var seq: Int64 = 0
    var keyKid = 0

    func authenticate(_ url: URL, callbackHost: String, callbackPath: String) async throws -> URL {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let state = items.first { $0.name == "state" }!.value!
        if callbackPath == "/auth/callback" {
            lock.withLock { lastChallenge = items.first { $0.name == "code_challenge" }?.value }
            return URL(string: "https://\(callbackHost)/auth/callback?code=abc&state=\(state)")!
        }
        let key = vaultKey.base64URL
        return URL(string: "https://\(callbackHost)/keys/callback#key=\(key)&kid=\(vaultKid)&sub=\(vaultSub ?? sub)&state=\(state)")!
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            requests.append(request)
            bodies.append(request.httpBody ?? Data())
        }
        let url = request.url!
        func reply(_ status: Int, _ body: Data = Data()) -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        func json(_ value: some Encodable, _ status: Int = 200) -> (Data, HTTPURLResponse) { reply(status, try! JSONEncoder().encode(value)) }

        if url.path.hasSuffix("/oauth2/token") {
            let form = Dictionary(uniqueKeysWithValues: URLComponents(string: "?" + String(data: request.httpBody!, encoding: .utf8)!)!
                .queryItems!.map { ($0.name, $0.value!) })
            if form["grant_type"] == "authorization_code" {
                guard GhentiSession.challenge(form["code_verifier"]!) == lastChallenge else { return reply(400) }
            } else if form["refresh_token"] != "refresh-\(issuedRefresh)" {
                return reply(400)  // a used refresh token is dead once rotated
            }
            issuedRefresh += 1
            let claims = try! JSONSerialization.data(withJSONObject: ["sub": sub, "name": "Ada", "email": "ada@example.com"])
            return reply(200, try! JSONSerialization.data(withJSONObject: [
                "access_token": "access-\(issuedRefresh)", "refresh_token": "refresh-\(issuedRefresh)", "expires_in": 3600,
                "id_token": "e30.\(claims.base64URL).sig",
            ]))
        }
        if url.path.hasSuffix("/oauth2/revoke") { return reply(200) }

        // Glide API
        let parts = url.path.split(separator: "/").map(String.init).drop { $0 != "v1" }.dropFirst()
        return lock.withLock { () -> (Data, HTTPURLResponse) in
            switch (request.httpMethod!, parts.first, parts.dropFirst().first.flatMap(UUID.init(uuidString:))) {
            case ("GET", "account", _):
                return json(GlideAPI.Account(keyKid: keyKid, records: records.count, audioBytes: 0, training: .init(enabled: false, items: 0)))
            case ("GET", "records", nil):
                let after = Int64(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "after" }!.value!)!
                let items = records.values.filter { $0.seq > after }.sorted { $0.seq < $1.seq }
                return json(GlideAPI.Page(items: items, next: nil))
            case ("PUT", "records", let id?):
                struct Body: Decodable { let kid: Int; let sealed: Data; let baseRevision: Int }
                let body = try! JSONDecoder().decode(Body.self, from: request.httpBody!)
                let current = records[id]
                if (current?.revision ?? 0) != body.baseRevision { return json(current!, 409) }
                seq += 1
                keyKid = max(keyKid, body.kid)
                let stored = GlideAPI.Record(id: id, kid: body.kid, revision: (current?.revision ?? 0) + 1, seq: seq, deleted: false,
                                             sealed: body.sealed, hasAudio: audio[id] != nil)
                records[id] = stored
                return json(stored)
            case ("DELETE", "records", let id?):
                seq += 1
                records[id] = GlideAPI.Record(id: id, kid: 1, revision: (records[id]?.revision ?? 0) + 1, seq: seq, deleted: true,
                                              sealed: nil, hasAudio: false)
                audio[id] = nil
                return reply(204)
            case ("PUT", "audio", let id?):
                audio[id] = request.httpBody
                if var record = records[id] {
                    seq += 1
                    record.hasAudio = true
                    record.seq = seq
                    records[id] = record
                }
                return reply(204)
            case ("GET", "audio", let id?):
                return audio[id].map { reply(200, $0) } ?? reply(404)
            default:
                return reply(404)
            }
        }
    }
}
