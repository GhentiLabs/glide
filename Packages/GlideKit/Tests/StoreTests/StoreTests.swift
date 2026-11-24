import Foundation
import GlideCore
import Testing
@testable import Store

@MainActor @Suite struct StoreTests {
    @Test func survivesRelaunchAndKeepsNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        store.add(DictationRecord(app: "com.apple.TextEdit", rawTranscript: "one", refinedText: "One."))
        store.add(DictationRecord(app: nil, rawTranscript: "two", refinedText: "Two."))
        let word = DictionaryEntry(word: "kubectl", heardAs: ["cube control"])
        store.upsert(word)
        store.countUses([word.id, word.id])

        let reopened = Store(directory: dir)
        #expect(reopened.records.map(\.rawTranscript) == ["two", "one"])
        #expect(reopened.dictionary.first?.uses == 2)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("history.json").path)[.posixPermissions]
        #expect(mode as? Int == 0o600)

        reopened.remove(entries: [word.id])
        reopened.clearHistory()
        #expect(Store(directory: dir).records.isEmpty && Store(directory: dir).dictionary.isEmpty)
    }

    @Test func correctionReplacesTheFinalTextAndSurvivesRelaunch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory)
        let record = DictationRecord(
            app: nil, rawTranscript: "see you thursday", refinedText: "See you Thursday.", finalText: "See you Thurdsay.",
            diff: [EditSpan(pastedWords: 2..<3, finalWords: 2..<3, before: "Thursday.", after: "Thurdsay.", kind: .misheard)],
            verdict: .edited)
        store.add(record)

        store.correct(record.id, to: "  See you on Thursday.\n")
        let reloaded = Store(directory: directory).records[0]
        #expect(reloaded.finalText == "See you on Thursday.")
        #expect(reloaded.verdict == .edited)
        #expect(reloaded.diff.isEmpty)  // the mistyped span must not outlive the correction

        store.correct(record.id, to: "See you Thursday.")
        #expect(store.records[0].finalText == nil)
        #expect(store.records[0].verdict == .untouched)

        store.correct(record.id, to: "   ")
        #expect(store.records[0].finalText == nil)  // an empty edit changes nothing
    }
}
