import CryptoKit
import Foundation
import GlideCore

/// Each dictation's recording as Opus, sealed at rest with a key that stays in this Mac's keychain.
public struct AudioStore: Sendable {
    public let directory: URL
    private let key: SymmetricKey

    public init(directory: URL, key: SymmetricKey) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        self.directory = directory
        self.key = key
    }

    public static var defaultDirectory: URL { Store.defaultDirectory.appendingPathComponent("Audio", isDirectory: true) }

    public func save(_ opus: Data, for id: UUID) throws {
        let box = try AES.GCM.seal(opus, using: key, authenticating: aad(id))
        try box.combined!.write(to: url(id), options: .atomic)
    }

    public func load(_ id: UUID) -> Data? {
        guard let sealed = try? Data(contentsOf: url(id)), let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: aad(id))
    }

    public func has(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: url(id).path) }

    public func remove(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }

    public func removeAll() {
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Recordings that taught nothing go after `days`; recordings of corrected dictations stay for training and testing.
    public func prune(_ records: [DictationRecord], olderThan days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let keep = Set(records.filter { $0.verdict == .edited || $0.time > cutoff }.map(\.id))
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !keep.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".opus.sealed") }
    private func aad(_ id: UUID) -> Data { Data("glide/local/audio|\(id.uuidString.lowercased())".utf8) }
}
