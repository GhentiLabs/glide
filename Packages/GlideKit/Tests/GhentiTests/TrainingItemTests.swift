import Foundation
import GlideCore
import Testing
@testable import Ghenti

@Suite struct TrainingItemTests {
    private func record(_ raw: String, pasted: String? = nil, final: String? = nil, app: String? = "com.apple.mail") -> DictationRecord {
        var record = DictationRecord(app: app, rawTranscript: raw, refinedText: pasted ?? raw, finalText: final)
        record.verdict = final == nil ? .untouched : .edited
        return record
    }

    @Test func contactDetailsAndNumbersAreReplaced() throws {
        let item = TrainingItem(anonymizing: record(
            "email me at jordan.lee@example.org or call 415-555-0172, account 4111 1111 1111 1111, see https://example.org/plans"))
        for leaked in ["jordan.lee@example.org", "415-555-0172", "4111 1111 1111 1111", "example.org/plans"] {
            #expect(!item.rawTranscript.contains(leaked), "\(leaked) leaked: \(item.rawTranscript)")
        }
        #expect(item.rawTranscript.contains("<EMAIL_1>"))
        #expect(item.rawTranscript.contains("<PHONE_1>"))
    }

    @Test func aNameGetsOnePlaceholderInEveryText() throws {
        let item = TrainingItem(anonymizing: record(
            "Tell Margaret Holloway the launch moved to Thursday in Chicago",
            pasted: "Tell Margaret Holloway the launch moved to Thursday in Chicago.",
            final: "Tell Margaret Holloway the launch moved to Friday in Chicago."))
        for text in [item.rawTranscript, item.pastedText, item.finalText ?? ""] {
            #expect(!text.contains("Margaret") && !text.contains("Holloway") && !text.contains("Chicago"), "\(text)")
        }
        let placeholder = try #require(item.pastedText.split(separator: " ").dropFirst().first)
        #expect(item.rawTranscript.contains(placeholder) && item.finalText!.contains(placeholder))
    }

    @Test func editsAreRedactedWithTheSamePlaceholders() throws {
        var source = record("send it to sam@example.com", final: "send it to sam@example.com today")
        source.diff = [EditSpan(pastedWords: 4..<4, finalWords: 4..<5, before: "sam@example.com", after: "sam@example.com today", kind: .addition)]
        let item = TrainingItem(anonymizing: source)
        #expect(item.edits == [.init(before: "<EMAIL_1>", after: "<EMAIL_1> today", kind: .addition)])
    }

    @Test func nothingIdentifyingIsEncoded() throws {
        let item = TrainingItem(anonymizing: record("ship it", app: "com.tinyspeck.slackmacgap"))
        let json = try #require(String(data: JSONEncoder().encode(item), encoding: .utf8))
        #expect(item.category == .chat)
        for key in ["\"id\"", "\"time\"", "\"app\"", "\"modified\"", "slackmacgap"] { #expect(!json.contains(key), "\(key) in \(json)") }
    }

    @Test func categories() {
        #expect(TrainingItem.category(app: "com.microsoft.VSCode", field: .native) == .code)
        #expect(TrainingItem.category(app: "com.example.anything", field: .terminal) == .code)
        #expect(TrainingItem.category(app: "com.apple.Notes", field: .native) == .document)
        #expect(TrainingItem.category(app: "com.apple.Safari", field: .web) == .other)
        #expect(TrainingItem.category(app: nil, field: nil) == .other)
    }

    @Test func framingKeepsTheRecordingAtItsOwnSize() throws {
        let item = TrainingItem(anonymizing: record("hello there"))
        let opus = Data((0..<3000).map { UInt8($0 & 0xFF) })
        let framed = try item.framed(audio: opus)
        let length = Int(framed.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        #expect(try JSONDecoder().decode(TrainingItem.self, from: framed.dropFirst(4).prefix(length)) == item)
        #expect(framed.suffix(from: 4 + length) == opus)
        #expect(framed.count == 4 + length + opus.count)
    }

    @Test func trainingIDIsStableButUnlinkable() {
        let recordID = UUID()
        let key = Data(repeating: 7, count: 32)
        let id = TrainingItem.id(for: recordID, appKey: key)
        #expect(id == TrainingItem.id(for: recordID, appKey: key))
        #expect(id != recordID)
        #expect(id != TrainingItem.id(for: recordID, appKey: Data(repeating: 8, count: 32)))
        #expect(id != TrainingItem.id(for: UUID(), appKey: key))
        #expect(id.uuidString.dropFirst(14).first == "8")
    }
}
