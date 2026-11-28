import Foundation
import GlideCore
import Testing
@testable import Learning

@Suite struct CleanupPairsTests {
    private func record(_ raw: String, pasted: String, final: String?, at minute: Int) -> DictationRecord {
        var r = DictationRecord(time: Date(timeIntervalSince1970: Double(minute) * 60), app: nil, rawTranscript: raw, refinedText: pasted)
        if let final {
            r.finalText = final
            r.diff = Labeller.label(raw: raw, pasted: pasted, final: final)
            r.verdict = .edited
        } else {
            r.verdict = .untouched
        }
        return r
    }

    /// The cleanup model dropped words the user said; putting them back is exactly what it should learn.
    private func restored(at minute: Int) -> DictationRecord {
        record("Could we move uh the standup to Thursday?", pasted: "The standup to Thursday?", final: "Could we move the standup to Thursday?", at: minute)
    }

    @Test func restoredWordsTeachTheCleanupModel() {
        #expect(restored(at: 0).diff.map(\.kind) == [.restored, .formatting])
        let pairs = Labeller.cleanupPairs(from: (0..<5).map(restored))
        #expect(pairs.count == 5)
        #expect(pairs[0].input == "Could we move uh the standup to Thursday?")
        #expect(pairs[0].target == "Could we move the standup to Thursday?")
    }

    @Test func tooFewCorrectionsTrainNothing() {
        #expect(Labeller.cleanupPairs(from: (0..<4).map(restored)).isEmpty)
    }

    @Test func misheardRewrittenAndExcludedRecordsAreLeftOut() {
        let misheard = record("Deploy it to cooper netties today.", pasted: "Deploy it to cooper netties today.", final: "Deploy it to Kubernetes today.", at: 10)
        let rewrite = record("Send the deck.", pasted: "Send the deck.", final: "Please send the slides to the whole team by noon.", at: 11)
        var excluded = restored(at: 12)
        excluded.excluded = true
        let pairs = Labeller.cleanupPairs(from: (0..<5).map(restored) + [misheard, rewrite, excluded])
        #expect(pairs.count == 5)
    }

    @Test func keptDictationsAreMixedInNewestFirstAndCapped() {
        let kept = (100..<120).map { record("Ship it on Friday.", pasted: "ship it on Friday.", final: nil, at: $0) }
        let pairs = Labeller.cleanupPairs(from: kept + (0..<5).map(restored))
        #expect(pairs.count == 15)  // 5 corrections and 10 kept dictations
        #expect(pairs.last?.target == "Ship it on Friday.")  // pasted mid-sentence, so the capital comes back
        #expect(pairs.map(\.input).prefix(5).allSatisfy { $0.hasPrefix("Could") })  // oldest first
    }
}
