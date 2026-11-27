import CryptoKit
import Foundation
import GlideCore
import NaturalLanguage

/// What Glide shares for training, built on the Mac before sealing: no account, no time, no record id,
/// the app reduced to a category, and names, places, contact details and long numbers in the text
/// replaced by placeholders. The recording goes as is. Format: services/api/openapi.yaml.
public struct TrainingItem: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable { case email, chat, code, document, other }

    public struct Edit: Codable, Sendable, Equatable {
        public var before: String
        public var after: String
        public var kind: EditSpan.Kind
    }

    public var version = 1
    public var category: Category
    public var rawTranscript: String
    public var pastedText: String
    public var finalText: String?
    public var edits: [Edit]
    public var verdict: Verdict

    public init(anonymizing record: DictationRecord) {
        var redactor = Redactor()
        let texts = [record.rawTranscript, record.refinedText, record.finalText ?? ""] + record.diff.flatMap { [$0.before, $0.after] }
        redactor.learn(texts)
        category = Self.category(app: record.app, field: record.fieldKind)
        rawTranscript = redactor.redact(record.rawTranscript)
        pastedText = redactor.redact(record.refinedText)
        finalText = record.finalText.map(redactor.redact)
        edits = record.diff.map { Edit(before: redactor.redact($0.before), after: redactor.redact($0.after), kind: $0.kind) }
        verdict = record.verdict
    }

    /// JSON length (4 bytes, big-endian) | JSON | recording.
    public func framed(audio: Data?) throws -> Data {
        let json = try JSONEncoder().encode(self)
        var length = UInt32(json.count).bigEndian
        return Data(bytes: &length, count: 4) + json + (audio ?? Data())
    }

    /// A stable id for a record's training item that only the person's own devices can work out,
    /// so a later edit replaces the item but nobody can match it to the synced record.
    public static func id(for record: UUID, appKey: Data) -> UUID {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: appKey), info: Data("glide/v1/training-id".utf8), outputByteCount: 32)
        var bytes = Array(HMAC<SHA256>.authenticationCode(for: Data(record.uuidString.lowercased().utf8), using: key).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x80  // UUID version 8 (custom)
        bytes[8] = bytes[8] & 0x3F | 0x80  // RFC 9562 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func category(app: String?, field: FieldKind?) -> Category {
        if field == .terminal { return .code }
        guard let app = app?.lowercased() else { return .other }
        let table: [(Category, [String])] = [
            (.email, ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.superhuman", "com.google.gmail", "it.bloop.airmail"]),
            (.chat, ["com.tinyspeck.slackmacgap", "com.apple.mobilesms", "com.hnc.discord", "ru.keepcoder.telegram", "net.whatsapp",
                     "com.microsoft.teams", "us.zoom", "org.whispersystems.signal", "com.facebook.archon"]),
            (.code, ["com.apple.dt.xcode", "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "dev.zed", "com.jetbrains",
                     "com.apple.terminal", "com.googlecode.iterm2", "dev.warp", "com.mitchellh.ghostty", "com.sublimetext"]),
            (.document, ["com.apple.iwork", "com.microsoft.word", "com.microsoft.powerpoint", "com.microsoft.excel", "com.apple.notes",
                         "md.obsidian", "notion.id", "com.apple.textedit", "com.ulyssesapp", "com.bear-writer", "com.craft"]),
        ]
        return table.first { $0.1.contains { app.hasPrefix($0) } }?.0 ?? .other
    }
}

/// Finds identifying spans in all of an item's texts first, then replaces each one everywhere,
/// so "Sam" is <NAME_1> in the transcript, the pasted text and the final text alike.
struct Redactor {
    private(set) var placeholders: [String: String] = [:]
    private var counts: [String: Int] = [:]

    mutating func learn(_ texts: [String]) {
        for text in texts where !text.isEmpty {
            for (span, label) in Self.spans(in: text) { add(span, label) }
        }
    }

    func redact(_ text: String) -> String {
        var out = text
        // Longest first, so "Sam Rivera" goes before "Sam".
        for original in placeholders.keys.sorted(by: { $0.count > $1.count }) {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: original) + "(?![\\p{L}\\p{N}])"
            out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: placeholders[original]!),
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    private mutating func add(_ span: String, _ label: String) {
        let span = span.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard span.count >= 2, placeholders.keys.first(where: { $0.caseInsensitiveCompare(span) == .orderedSame }) == nil else { return }
        counts[label, default: 0] += 1
        placeholders[span] = "<\(label)_\(counts[label]!)>"
    }

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
        | NSTextCheckingResult.CheckingType.phoneNumber.rawValue | NSTextCheckingResult.CheckingType.address.rawValue)
    /// Six or more digits, possibly broken up: account, card and ID numbers.
    private static let longNumber = try! NSRegularExpression(pattern: "\\d(?:[\\d .-]{4,}\\d)")
    private static let email = try! NSRegularExpression(pattern: "[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)+")

    static func spans(in text: String) -> [(String, String)] {
        let whole = NSRange(text.startIndex..., in: text)
        func string(_ range: NSRange) -> String { String(text[Range(range, in: text)!]) }
        var out: [(String, String)] = []
        for match in email.matches(in: text, range: whole) { out.append((string(match.range), "EMAIL")) }
        for match in detector.matches(in: text, range: whole) {
            switch match.resultType {
            case .phoneNumber: out.append((string(match.range), "PHONE"))
            case .address: out.append((string(match.range), "ADDRESS"))
            default: if match.url?.scheme != "mailto" { out.append((string(match.range), "LINK")) }
            }
        }
        for match in longNumber.matches(in: text, range: whole) where string(match.range).filter(\.isNumber).count >= 6 {
            out.append((string(match.range), "NUMBER"))
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let labels: [NLTag: String] = [.personalName: "NAME", .placeName: "PLACE", .organizationName: "ORG"]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if let tag, let label = labels[tag] { out.append((String(text[range]), label)) }
            return true
        }
        return out
    }
}
