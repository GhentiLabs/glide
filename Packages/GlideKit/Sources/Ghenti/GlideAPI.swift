import Foundation

/// The Glide API at glide.ghenti.com/v1 (services/api/openapi.yaml). Everything it carries is sealed on this Mac first.
public struct GlideAPI: Sendable {
    public struct Record: Codable, Sendable, Equatable {
        public var id: UUID
        public var kid: Int
        public var revision: Int
        public var seq: Int64
        public var deleted: Bool
        public var sealed: Data?
        public var hasAudio: Bool
    }

    public struct Page: Codable, Sendable {
        public var items: [Record]
        public var next: Int64?
    }

    public struct Account: Codable, Sendable {
        public var keyKid: Int
        public var records: Int
        public var audioBytes: Int64
        public var training: Consent
    }

    public struct Consent: Codable, Sendable {
        public var enabled: Bool
        public var items: Int
    }

    public struct TrainingKey: Codable, Sendable {
        public var version: Int
        public var publicKeyPem: String
    }

    public enum APIError: Error, Equatable {
        case conflict(Record)
        case status(Int, String)
    }

    let base: URL
    let http: any HTTPTransport
    let bearer: @Sendable () async throws -> String

    public init(base: URL, http: any HTTPTransport = URLSession.shared, bearer: @escaping @Sendable () async throws -> String) {
        self.base = base
        self.http = http
        self.bearer = bearer
    }

    public func account() async throws -> Account { try await json("GET", "account") }

    public func records(after cursor: Int64, limit: Int = 200) async throws -> Page {
        try await json("GET", "records", query: ["after": String(cursor), "limit": String(limit)])
    }

    /// 409 comes back as `.conflict` carrying the server's copy.
    public func put(_ id: UUID, kid: Int, sealed: Data, baseRevision: Int) async throws -> Record {
        struct Body: Encodable { let kid: Int; let sealed: Data; let baseRevision: Int }
        return try await json("PUT", "records/\(id.uuidString.lowercased())", body: Body(kid: kid, sealed: sealed, baseRevision: baseRevision))
    }

    public func delete(_ id: UUID) async throws { try await empty("DELETE", "records/\(id.uuidString.lowercased())") }
    public func deleteAllSynced() async throws { try await empty("DELETE", "records") }

    public func putAudio(_ id: UUID, sealed: Data) async throws {
        try await empty("PUT", "audio/\(id.uuidString.lowercased())", raw: sealed)
    }

    public func audio(_ id: UUID) async throws -> Data {
        try await send("GET", "audio/\(id.uuidString.lowercased())").0
    }

    public func trainingKey() async throws -> TrainingKey { try await json("GET", "training/key") }

    public func setTrainingConsent(_ enabled: Bool) async throws -> Consent {
        struct Body: Encodable { let enabled: Bool }
        return try await json("PUT", "training/consent", body: Body(enabled: enabled))
    }

    public func putTrainingItem(_ id: UUID, keyVersion: Int, item: TrainingCrypto.Item) async throws {
        struct Body: Encodable { let keyVersion: Int; let wrappedKey: Data; let sealed: Data }
        try await empty("PUT", "training/items/\(id.uuidString.lowercased())", json: Body(keyVersion: keyVersion, wrappedKey: item.wrappedKey, sealed: item.sealed))
    }

    public func deleteTrainingItem(_ id: UUID) async throws {
        try await empty("DELETE", "training/items/\(id.uuidString.lowercased())")
    }

    // MARK: Transport

    private func json<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:], body: (any Encodable)? = nil) async throws -> T {
        let (data, _) = try await send(method, path, query: query, json: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func empty(_ method: String, _ path: String, json: (any Encodable)? = nil, raw: Data? = nil) async throws {
        _ = try await send(method, path, json: json, raw: raw)
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], json: (any Encodable)? = nil, raw: Data? = nil)
        async throws -> (Data, HTTPURLResponse)
    {
        var url = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: url.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(json)
        } else if let raw {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = raw
        }
        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200..<300: return (data, response)
        case 409:
            if let current = try? JSONDecoder().decode(Record.self, from: data) { throw APIError.conflict(current) }
            fallthrough
        default:
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError.status(response.statusCode, code ?? "")
        }
    }
}
