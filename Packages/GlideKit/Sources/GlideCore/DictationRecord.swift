import Foundation

/// One dictation, as history and learning see it.
public struct DictationRecord: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var time: Date
    /// Bundle identifier of the app the text went into.
    public var app: String?
    /// Exactly what the recognizer returned.
    public var rawTranscript: String
    /// After the rules layer; what was pasted.
    public var refinedText: String
    /// The field's text once the user stopped editing, if it could be tracked.
    public var finalText: String?
    public var diff: [EditSpan]
    public var verdict: Verdict
    public var skipReason: SkipReason?
    /// Where `finalText` came from. An edit in Glide's history outranks one read from the field.
    public var finalSource: FinalSource?
    /// How the field was read, for the per-app tracking report.
    public var fieldKind: FieldKind?
    /// The labeller version that produced `diff`, so labels can be rebuilt.
    public var labellerVersion: Int?
    /// The user marked this as not a correction; it never trains anything.
    public var excluded: Bool?
    /// Last change on any device; the newer copy wins when two devices change one record.
    public var modified: Date?

    public init(
        id: UUID = UUID(), time: Date = .now, app: String?, rawTranscript: String, refinedText: String,
        finalText: String? = nil, diff: [EditSpan] = [], verdict: Verdict = .pending, skipReason: SkipReason? = nil
    ) {
        self.id = id
        self.time = time
        self.app = app
        self.rawTranscript = rawTranscript
        self.refinedText = refinedText
        self.finalText = finalText
        self.diff = diff
        self.verdict = verdict
        self.skipReason = skipReason
    }
}

/// One changed run of words between the pasted text and the final text.
public struct EditSpan: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// The user put back words the rules or refiner changed.
        case restored
        case formatting, cleanup, misheard, rewrite, addition
    }

    /// Word range in the pasted text; empty for a pure insertion.
    public var pastedWords: Range<Int>
    /// Word range in the final text; empty for a pure deletion.
    public var finalWords: Range<Int>
    public var before: String
    public var after: String
    public var kind: Kind

    public init(pastedWords: Range<Int>, finalWords: Range<Int>, before: String, after: String, kind: Kind) {
        self.pastedWords = pastedWords
        self.finalWords = finalWords
        self.before = before
        self.after = after
        self.kind = kind
    }
}

public enum Verdict: String, Codable, Sendable {
    /// Still being tracked.
    case pending
    /// Left as pasted.
    case untouched
    case edited
    /// Could not be tracked; see the skip reason.
    case skipped
}

public enum SkipReason: String, Codable, Sendable {
    case fieldUnreadable
    case passwordField
    case pastedTextNotFound
    case focusLost
    case replacedByNewDictation
    /// Learning from edits is off, so nothing after the paste was read.
    case learningOff
}

public enum FinalSource: String, Codable, Sendable { case field, history }

public enum FieldKind: String, Codable, Sendable { case native, web, terminal }
