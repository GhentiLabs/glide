import CryptoKit
import Foundation
import Security

/// Sealing for synced records and audio, keyed by Glide's app key from the Ghenti vault.
/// The formats are fixed by services/api/openapi.yaml; the server checks only their shape.
public struct SyncCrypto: Sendable {
    public enum Kind: String, Sendable { case record, audio }
    public enum CryptoError: Error, Equatable { case badEnvelope, badKey }

    static let version: UInt8 = 0x01
    private let records: SymmetricKey
    private let audio: SymmetricKey
    public let kid: Int
    public let sub: String

    /// `appKey` is the 32 bytes the vault handed over for generation `kid` of user `sub`.
    public init(appKey: Data, kid: Int, sub: String) throws {
        guard appKey.count == 32 else { throw CryptoError.badKey }
        let ikm = SymmetricKey(data: appKey)
        records = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, info: Data("glide/v1/records".utf8), outputByteCount: 32)
        audio = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, info: Data("glide/v1/audio".utf8), outputByteCount: 32)
        self.kid = kid
        self.sub = sub
    }

    public func seal(_ plaintext: Data, _ kind: Kind, id: UUID) throws -> Data {
        try Self.seal(plaintext, key: key(kind), aad: aad(kind, id: id, kid: kid))
    }

    /// `kid` is the generation the item was sealed under; anything else fails to open.
    public func open(_ sealed: Data, _ kind: Kind, id: UUID, kid: Int) throws -> Data {
        try Self.open(sealed, key: key(kind), aad: aad(kind, id: id, kid: kid))
    }

    private func key(_ kind: Kind) -> SymmetricKey { kind == .record ? records : audio }

    private func aad(_ kind: Kind, id: UUID, kid: Int) -> Data {
        Data("glide/v1|\(kind.rawValue)|\(sub)|\(id.uuidString.lowercased())|\(kid)".utf8)
    }

    /// 0x01 | nonce (12) | ciphertext | tag (16), AES-256-GCM.
    static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        return Data([version]) + box.combined!
    }

    static func open(_ sealed: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard sealed.count >= 1 + 12 + 16, sealed.first == version else { throw CryptoError.badEnvelope }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.dropFirst()), using: key, authenticating: aad)
    }
}

/// Items shared for training: sealed with a fresh key, which is encrypted to Ghenti's training public key
/// (OpenBao transit `glide-training`, RSA-OAEP with SHA-256). Glide can't read them back; Ghenti's training job can.
public enum TrainingCrypto {
    public struct Item: Sendable {
        public let wrappedKey: Data
        public let sealed: Data
    }

    public enum TrainingError: Error { case badPublicKey, wrapFailed }

    /// `id` is the training id; no account goes into the item, its AAD or its storage path.
    public static func seal(_ plaintext: Data, id: UUID, publicKeyPEM: String) throws -> Item {
        let publicKey = try rsaPublicKey(pem: publicKeyPEM)
        let itemKey = SymmetricKey(size: .bits256)
        let raw = itemKey.withUnsafeBytes { Data($0) }
        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, raw as CFData, &error) as Data? else {
            throw TrainingError.wrapFailed
        }
        let aad = Data("glide/v1|training|\(id.uuidString.lowercased())".utf8)
        return Item(wrappedKey: wrapped, sealed: try SyncCrypto.seal(plaintext, key: itemKey, aad: aad))
    }

    /// Accepts PEM "PUBLIC KEY" (SubjectPublicKeyInfo, as OpenBao returns it) or "RSA PUBLIC KEY" (PKCS#1).
    static func rsaPublicKey(pem: String) throws -> SecKey {
        let body = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
            .filter { !$0.isWhitespace }
        guard var der = Data(base64Encoded: body) else { throw TrainingError.badPublicKey }
        if pem.contains("BEGIN PUBLIC KEY") { der = try pkcs1(fromSPKI: der) }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { throw TrainingError.badPublicKey }
        return key
    }

    /// Security wants PKCS#1; SubjectPublicKeyInfo wraps it in SEQUENCE { algorithm, BIT STRING { PKCS#1 } }.
    private static func pkcs1(fromSPKI der: Data) throws -> Data {
        var bytes = [UInt8](der)[...]
        func length() throws -> Int {
            guard let first = bytes.popFirst() else { throw TrainingError.badPublicKey }
            if first < 0x80 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count <= 4, bytes.count >= count else { throw TrainingError.badPublicKey }
            let value = bytes.prefix(count).reduce(0) { $0 << 8 | Int($1) }
            bytes = bytes.dropFirst(count)
            return value
        }
        func expect(_ tag: UInt8) throws {
            guard bytes.popFirst() == tag else { throw TrainingError.badPublicKey }
        }
        try expect(0x30); _ = try length()  // SubjectPublicKeyInfo
        try expect(0x30); let algorithm = try length()
        bytes = bytes.dropFirst(algorithm)
        try expect(0x03); _ = try length()  // BIT STRING
        guard bytes.popFirst() == 0x00 else { throw TrainingError.badPublicKey }  // no unused bits
        return Data(bytes)
    }
}
