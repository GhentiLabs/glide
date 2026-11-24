import Foundation

/// A word Glide should spell a particular way, and what the recognizer tends to hear instead.
public struct DictionaryEntry: Identifiable, Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case user, learned }

    public var id: UUID
    public var word: String
    /// Forms the recognizer produces for this word; each is replaced by `word`.
    public var heardAs: [String]
    public var source: Source
    public var added: Date
    public var uses: Int

    public init(id: UUID = UUID(), word: String, heardAs: [String] = [], source: Source = .user, added: Date = .now, uses: Int = 0) {
        self.id = id
        self.word = word
        self.heardAs = heardAs
        self.source = source
        self.added = added
        self.uses = uses
    }
}
