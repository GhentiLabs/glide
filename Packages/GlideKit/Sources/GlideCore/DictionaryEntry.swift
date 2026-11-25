import Foundation

/// A word Glide boosts while decoding, and what the recognizer heard instead when it was learned.
/// `heardAs` helps the booster find the spot; it never replaces text on its own, since the audio has to support the word.
public struct DictionaryEntry: Identifiable, Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case user, learned }

    public var id: UUID
    public var word: String
    /// Forms the recognizer produces for this word; each is replaced by `word`.
    public var heardAs: [String]
    public var source: Source
    public var added: Date
    /// The dictation a learned word came from, so a later correction of that dictation can take it back.
    public var record: UUID?

    public init(id: UUID = UUID(), word: String, heardAs: [String] = [], source: Source = .user, added: Date = .now, record: UUID? = nil) {
        self.id = id
        self.word = word
        self.heardAs = heardAs
        self.source = source
        self.added = added
        self.record = record
    }
}
