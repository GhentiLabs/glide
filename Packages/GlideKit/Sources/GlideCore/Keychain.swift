import Foundation
import Security

/// Small secrets in the login keychain, readable only by this Mac while unlocked: tokens, the sync key, the audio key.
public struct Keychain: Sendable {
    public let service: String

    public init(service: String) { self.service = service }

    public func data(_ account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    @discardableResult
    public func set(_ data: Data, _ account: String) -> Bool {
        let update = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
        if SecItemUpdate(base(account) as CFDictionary, update) == errSecSuccess { return true }
        var add = base(account)
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func remove(_ account: String) { SecItemDelete(base(account) as CFDictionary) }

    public func value<T: Decodable>(_ type: T.Type, _ account: String) -> T? {
        data(account).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    @discardableResult
    public func set<T: Encodable>(value: T, _ account: String) -> Bool {
        (try? JSONEncoder().encode(value)).map { set($0, account) } ?? false
    }

    private func base(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
}
