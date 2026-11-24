import Foundation
import GlideCore
import Observation

/// History and dictionary, kept as JSON files readable only by this user.
/// shortcut: whole-file rewrites; move to SwiftData or SQLite once history reaches tens of thousands of records.
@MainActor @Observable
public final class Store {
    /// Newest first.
    public private(set) var records: [DictationRecord]
    public private(set) var dictionary: [DictionaryEntry]

    @ObservationIgnored private let recordsURL: URL
    @ObservationIgnored private let dictionaryURL: URL

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        recordsURL = directory.appendingPathComponent("history.json")
        dictionaryURL = directory.appendingPathComponent("dictionary.json")
        records = Self.load(recordsURL) ?? []
        dictionary = Self.load(dictionaryURL) ?? []
    }

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Glide", isDirectory: true)
    }

    public func add(_ record: DictationRecord) {
        records.insert(record, at: 0)
        save(records, to: recordsURL)
    }

    public func clearHistory() {
        records.removeAll()
        save(records, to: recordsURL)
    }

    public func upsert(_ entry: DictionaryEntry) {
        if let index = dictionary.firstIndex(where: { $0.id == entry.id }) {
            dictionary[index] = entry
        } else {
            dictionary.append(entry)
        }
        save(dictionary, to: dictionaryURL)
    }

    public func remove(entries ids: Set<UUID>) {
        dictionary.removeAll { ids.contains($0.id) }
        save(dictionary, to: dictionaryURL)
    }

    public func countUses(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { if let i = dictionary.firstIndex(where: { $0.id == id }) { dictionary[i].uses += 1 } }
        save(dictionary, to: dictionaryURL)
    }

    private static func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            assertionFailure("Glide could not save \(url.lastPathComponent): \(error)")
        }
    }
}
