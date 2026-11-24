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
}
