import Foundation
import Testing
@testable import Cleaner

@Suite struct CleanerTests {
    /// The model makes up a sentence for an empty transcript, so nothing without words may reach it.
    @Test func transcriptsWithoutWordsSkipTheModel() {
        #expect(!Cleaner.hasWords(""))
        #expect(!Cleaner.hasWords("  \n"))
        #expect(!Cleaner.hasWords("..."))
        #expect(Cleaner.hasWords("ok"))
        #expect(Cleaner.hasWords("42"))
    }

    @Test func passesTextThroughUntilLoaded() async {
        let cleaner = Cleaner(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(await cleaner.clean("") == "")
        #expect(await cleaner.clean("um send it friday") == "um send it friday")
    }

    @Test func rejectsEmptyAndRunawayOutput() {
        #expect(Cleaner.accepts("Send it Friday.", for: "um send it friday"))
        #expect(!Cleaner.accepts("", for: "send it"))
        #expect(!Cleaner.accepts(String(repeating: "and then ", count: 20), for: "send it"))
    }

    /// Values from training/coreml/qwen35.py's inputs_for([5, 6, 7, 7], 3, 4, 10).
    @Test func positionInputsMatchTheConverter() {
        let i = NeuralEngine.inputs(positions: [5, 6, 7, 7], active: 3, K: 4, max: 10)
        let cos = Array(i.cos[64..<67]), rotated = Array(i.cos[96..<99])
        for (got, want) in zip(cos + rotated, [0.96017027, -0.88505429, -0.58123732, 0.96017027, -0.88505429, -0.58123732] as [Float]) {
            #expect(abs(got - want) < 1e-6)
        }
        #expect(abs(i.sin[2 * 64 + 1] - -0.88592386) < 1e-6)
        let open = [6, 7, 8, 8]  // positions each row may attend to: up to its own, padding rows up to the last real one
        #expect(i.mask == open.flatMap { n in (0..<10).map { $0 < n ? 0 : -1e4 } })
        #expect(i.write.indices.filter { i.write[$0] == 1 } == [5 * 4 + 0, 6 * 4 + 1, 7 * 4 + 2])
        #expect(i.active == [1, 1, 1, 0])
        #expect(i.pick.indices.filter { i.pick[$0] == 1 } == [3, 7 + 4, 14 + 5])
    }
}

/// Runs the installed model, so it is skipped on a Mac without it.
@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: Cleaner.modelDirectory.appendingPathComponent("embed.bin").path)))
struct NeuralEngineTests {
    /// What training/coreml/power_bench.py's Python runner gives for the same made-up sentences.
    static let python = [
        "um so can you send me the report by friday": "Um, so can you send me the report by friday?",
        "Could we move uh the standup to Thursday?": "Could we move the standup to Thursday?",
        "I think we should use twenty five percent of the budget for marketing": "I think we should use 25% of the budget for marketing.",
        "send it to Tom no wait Sarah": "Send it to Sarah.",
        "okay so the plan for next week is we finish the onboarding flow then uh we start on the billing page and if we have time we fix the export bug":
            "Okay, so the plan for next week is we finish the onboarding flow, then we start on the billing page, and if we have time, we fix the export bug.",
    ]

    /// Without guesses the Python runner drops one comma here: fp16 sums differ with how many tokens go in each call, and
    /// that flips a near-tie.
    static let pythonWithoutGuesses = python.merging([
        "okay so the plan for next week is we finish the onboarding flow then uh we start on the billing page and if we have time we fix the export bug":
            "Okay, so the plan for next week is we finish the onboarding flow, then we start on the billing page and if we have time, we fix the export bug.",
    ]) { $1 }

    @Test func matchesThePythonRunnerWithAndWithoutGuesses() async throws {
        let engine = try await NeuralEngine(directory: Cleaner.modelDirectory)
        #expect(try engine.promptIDs("a").count == 78)
        for (input, output) in Self.python {
            #expect(try engine.generate(input) == output)
            #expect(try engine.generate(input, speculate: false) == Self.pythonWithoutGuesses[input])
        }
    }

    @Test func leavesDictationsTooLongForTheCacheAlone() async throws {
        let engine = try await NeuralEngine(directory: Cleaner.modelDirectory)
        #expect(try engine.generate(String(repeating: "send the report to Sarah and ", count: 40)) == nil)
    }
}
