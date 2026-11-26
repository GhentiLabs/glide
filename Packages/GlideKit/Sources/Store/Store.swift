import Foundation
import GlideCore
import Observation

/// History and the vocabulary list, kept as JSON files readable only by this user.
/// shortcut: whole-file rewrites; move to SwiftData or SQLite once history reaches tens of thousands of records.
@MainActor @Observable
public final class Store {
    /// Newest first.
    public private(set) var records: [DictationRecord]
    public private(set) var dictionary: [DictionaryEntry]

    /// Called after every change to the vocabulary list, so the recognizer boosts the new list.
    @ObservationIgnored public var onVocabularyChange: (([DictionaryEntry]) -> Void)?
    /// Called after records change or go away on this Mac, so sync can send them. Changes from sync don't call it.
    @ObservationIgnored public var onRecordsChange: ((_ changed: [UUID], _ deleted: [UUID]) -> Void)?
    @ObservationIgnored private let recordsURL: URL
    @ObservationIgnored private let dictionaryURL: URL

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        recordsURL = directory.appendingPathComponent("history.json")
        dictionaryURL = directory.appendingPathComponent("dictionary.json")
        records = Self.load(recordsURL) ?? []
        dictionary = Self.load(dictionaryURL) ?? []
    }

    nonisolated public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Glide", isDirectory: true)
    }

    public func add(_ record: DictationRecord) {
        var record = record
        record.modified = .now
        records.insert(record, at: 0)
        save(records, to: recordsURL)
        onRecordsChange?([record.id], [])
    }

    /// What the edit tracker or the history editor settled on. An edit made in history outranks the tracker,
    /// so a mistyped edit in the field can be fixed and can't teach Glide the wrong thing.
    public func setFinal(
        _ id: UUID, text: String?, source: FinalSource, diff: [EditSpan], labellerVersion: Int,
        fieldKind: FieldKind? = nil, skipReason: SkipReason? = nil
    ) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if source == .field, records[index].finalSource == .history { return }
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if source == .history, text?.isEmpty != false { return }  // an empty edit in history changes nothing
        let changed = text.map { $0 != records[index].refinedText } ?? false
        records[index].finalText = changed ? text : nil
        records[index].diff = changed ? diff : []
        records[index].verdict = skipReason != nil ? .skipped : changed ? .edited : .untouched
        records[index].skipReason = skipReason
        records[index].finalSource = text == nil ? nil : source
        records[index].labellerVersion = labellerVersion
        if let fieldKind { records[index].fieldKind = fieldKind }
        records[index].modified = .now
        save(records, to: recordsURL)
        onRecordsChange?([id], [])
    }

    /// "Not a Correction": the record stays in history and never trains anything.
    public func exclude(_ id: UUID, _ excluded: Bool) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].excluded = excluded ? true : nil
        records[index].modified = .now
        save(records, to: recordsURL)
        onRecordsChange?([id], [])
    }

    public func clearHistory() {
        let ids = records.map(\.id)
        records.removeAll()
        save(records, to: recordsURL)
        onRecordsChange?([], ids)
    }

    /// A record from another device: inserted in time order, or replacing this Mac's copy.
    public func applyRemote(_ record: DictationRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: records.firstIndex { $0.time < record.time } ?? records.endIndex)
        }
        save(records, to: recordsURL)
    }

    /// Deleted on another device.
    public func removeRemote(_ ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        save(records, to: recordsURL)
    }

    public func upsert(_ entry: DictionaryEntry) {
        if let index = dictionary.firstIndex(where: { $0.id == entry.id }) {
            dictionary[index] = entry
        } else {
            dictionary.append(entry)
        }
        save(dictionary, to: dictionaryURL)
        onVocabularyChange?(dictionary)
    }

    public func remove(entries ids: Set<UUID>) {
        dictionary.removeAll { ids.contains($0.id) }
        save(dictionary, to: dictionaryURL)
        onVocabularyChange?(dictionary)
    }

    /// Settings' Delete Learning Data: every vocabulary word and every label goes; the history text stays.
    public func clearLearningData() {
        for i in records.indices { records[i].diff = [] }
        save(records, to: recordsURL)
        remove(entries: Set(dictionary.map(\.id)))
    }

    /// Takes back the words learned from one dictation, before it is relabelled or marked as not a correction.
    @discardableResult
    public func forgetWords(learnedFrom record: UUID) -> [DictionaryEntry] {
        let gone = dictionary.filter { $0.source == .learned && $0.record == record }
        if !gone.isEmpty { remove(entries: Set(gone.map(\.id))) }
        return gone
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
