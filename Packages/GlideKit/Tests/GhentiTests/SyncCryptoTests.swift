import CryptoKit
import Foundation
import Security
import Testing
@testable import Ghenti

@Suite struct SyncCryptoTests {
    let key = Data(repeating: 7, count: 32)
    let id = UUID()

    @Test func roundTripsAndBindsEverythingInTheAAD() throws {
        let crypto = try SyncCrypto(appKey: key, kid: 2, sub: "user-1")
        let sealed = try crypto.seal(Data("hello".utf8), .record, id: id)
        #expect(sealed.first == 0x01 && sealed.count == 1 + 12 + 5 + 16)
        #expect(try crypto.open(sealed, .record, id: id, kid: 2) == Data("hello".utf8))
        // Another record, kind, generation or user must not open it.
        #expect(throws: (any Error).self) { try crypto.open(sealed, .record, id: UUID(), kid: 2) }
        #expect(throws: (any Error).self) { try crypto.open(sealed, .audio, id: id, kid: 2) }
        #expect(throws: (any Error).self) { try crypto.open(sealed, .record, id: id, kid: 1) }
        #expect(throws: (any Error).self) { try SyncCrypto(appKey: key, kid: 2, sub: "user-2").open(sealed, .record, id: id, kid: 2) }
    }

    @Test func subkeysFollowTheContract() throws {
        // HKDF-SHA256(ikm: appKey, salt: empty, info: "glide/v1/records"), as the contract and any other client derive it.
        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key), info: Data("glide/v1/records".utf8), outputByteCount: 32)
        let sealed = try SyncCrypto(appKey: key, kid: 1, sub: "u").seal(Data("x".utf8), .record, id: id)
        let aad = Data("glide/v1|record|u|\(id.uuidString.lowercased())|1".utf8)
        #expect(try SyncCrypto.open(sealed, key: expected, aad: aad) == Data("x".utf8))
    }

    @Test func rejectsBadKeysAndEnvelopes() throws {
        #expect(throws: SyncCrypto.CryptoError.badKey) { try SyncCrypto(appKey: Data(count: 16), kid: 1, sub: "u") }
        let crypto = try SyncCrypto(appKey: key, kid: 1, sub: "u")
        #expect(throws: SyncCrypto.CryptoError.badEnvelope) { try crypto.open(Data([0x02]) + Data(count: 40), .record, id: id, kid: 1) }
        #expect(throws: SyncCrypto.CryptoError.badEnvelope) { try crypto.open(Data([0x01, 0, 0]), .record, id: id, kid: 1) }
    }

    @Test func trainingItemsOpenOnlyWithThePrivateKey() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil) as Data?)
        // OpenBao returns SubjectPublicKeyInfo PEM: the rsaEncryption algorithm header in front of PKCS#1.
        let header: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString = Data([0x03]) + derLength(pkcs1.count + 1) + Data([0x00]) + pkcs1
        let spki = Data([0x30]) + derLength(header.count + bitString.count) + Data(header) + bitString
        let pem = "-----BEGIN PUBLIC KEY-----\n" + spki.base64EncodedString(options: .lineLength64Characters) + "\n-----END PUBLIC KEY-----\n"

        let item = try TrainingCrypto.seal(Data("shared".utf8), id: id, sub: "u", publicKeyPEM: pem)
        let raw = try #require(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, item.wrappedKey as CFData, nil) as Data?)
        let aad = Data("glide/v1|training|u|\(id.uuidString.lowercased())".utf8)
        #expect(try SyncCrypto.open(item.sealed, key: SymmetricKey(data: raw), aad: aad) == Data("shared".utf8))
    }

    private func derLength(_ n: Int) -> Data {
        n < 0x80 ? Data([UInt8(n)]) : n < 0x100 ? Data([0x81, UInt8(n)]) : Data([0x82, UInt8(n >> 8), UInt8(n & 0xFF)])
    }
}
