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

        let reopened = Store(directory: dir)
        #expect(reopened.records.map(\.rawTranscript) == ["two", "one"])
        #expect(reopened.dictionary.first?.heardAs == ["cube control"])
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

        let fix = [EditSpan(pastedWords: 2..<2, finalWords: 2..<3, before: "", after: "on", kind: .addition)]
        store.setFinal(record.id, text: "  See you on Thursday.\n", source: .history, diff: fix, labellerVersion: 1)
        let reloaded = Store(directory: directory).records[0]
        #expect(reloaded.finalText == "See you on Thursday.")
        #expect(reloaded.verdict == .edited)
        #expect(reloaded.diff == fix)  // the mistyped span must not outlive the correction
        #expect(reloaded.finalSource == .history)

        // A late result from the field tracker can't overwrite what the user set in history.
        store.setFinal(record.id, text: "See you Thurdsay.", source: .field, diff: [], labellerVersion: 1)
        #expect(store.records[0].finalText == "See you on Thursday.")

        store.setFinal(record.id, text: "See you Thursday.", source: .history, diff: [], labellerVersion: 1)
        #expect(store.records[0].finalText == nil)
        #expect(store.records[0].verdict == .untouched)

        store.setFinal(record.id, text: "   ", source: .history, diff: [], labellerVersion: 1)
        #expect(store.records[0].verdict == .untouched)  // an empty edit changes nothing
    }

    @Test func forgettingARecordRemovesOnlyItsLearnedWords() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory)
        let record = UUID()
        store.upsert(DictionaryEntry(word: "Kubernetes", source: .learned, record: record))
        store.upsert(DictionaryEntry(word: "Grafana", source: .learned, record: UUID()))
        store.upsert(DictionaryEntry(word: "Ghenti", source: .user, record: record))
        #expect(store.forgetWords(learnedFrom: record).map(\.word) == ["Kubernetes"])
        #expect(store.dictionary.map(\.word) == ["Grafana", "Ghenti"])
    }
}
