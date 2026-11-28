import Foundation
import MLX
import Testing
@testable import Cleaner

@Suite struct ChunkedDeltaTests {
    /// The gated delta rule one token at a time: S ← S·g + β·(v − S·k)⊗k, out = S·q.
    static func sequential(_ q: [[[Float]]], _ k: [[[Float]]], _ v: [[[Float]]], _ logDecay: [[Float]], _ beta: [[Float]]) -> [[[Float]]] {
        let T = q.count, H = q[0].count, Dk = q[0][0].count, Dv = v[0][0].count
        var S = Array(repeating: Array(repeating: Array(repeating: Float(0), count: Dk), count: Dv), count: H)
        var out = Array(repeating: Array(repeating: Array(repeating: Float(0), count: Dv), count: H), count: T)
        for t in 0..<T {
            for h in 0..<H {
                let g = exp(logDecay[t][h])
                for i in 0..<Dv {
                    for j in 0..<Dk { S[h][i][j] *= g }
                    let predicted = (0..<Dk).reduce(Float(0)) { $0 + S[h][i][$1] * k[t][h][$1] }
                    for j in 0..<Dk { S[h][i][j] += beta[t][h] * (v[t][h][i] - predicted) * k[t][h][j] }
                    out[t][h][i] = (0..<Dk).reduce(Float(0)) { $0 + S[h][i][$1] * q[t][h][$1] }
                }
            }
        }
        return out
    }

    /// 37 tokens: two full chunks and a padded one.
    @Test func matchesTheTokenByTokenRule() {
        MLXRandom.seed(1)
        let (T, H, D) = (37, 2, 8)
        let q = MLXRandom.normal([T, H, D]) / 3, k = MLXRandom.normal([T, H, D])
        let kn = k * rsqrt((k * k).sum(axis: -1, keepDims: true))
        let v = MLXRandom.normal([T, H, D]), logDecay = -MLXRandom.uniform(low: 0, high: 2, [T, H]), beta = MLXRandom.uniform(low: 0, high: 1, [T, H])
        let got = Trainer.chunkedDelta(q, kn, v, logDecay, beta).asArray(Float.self)
        let nest3 = { (a: MLXArray) in (0..<T).map { t in (0..<H).map { h in a[t, h].asArray(Float.self) } } }
        let nest2 = { (a: MLXArray) in (0..<T).map { t in a[t].asArray(Float.self) } }
        let want = Self.sequential(nest3(q), nest3(kn), nest3(v), nest2(logDecay), nest2(beta)).flatMap { $0.flatMap { $0 } }
        let worst = zip(got, want).map { abs($0 - $1) }.max()!
        #expect(worst < 1e-4)
    }
}

/// Runs the installed model, so it is skipped on a Mac without it.
@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: Cleaner.modelDirectory.appendingPathComponent("train.json").path)))
struct TrainerTests {
    /// Teacher-forced on a cleanup the Neural Engine produced, the trainer predicts the same next tokens.
    @Test func predictsWhatTheNeuralEngineDoes() async throws {
        let engine = try await NeuralEngine(directory: Cleaner.modelDirectory)
        let trainer = try Trainer(directory: Cleaner.modelDirectory)
        let input = "okay so the plan for next week is we finish the onboarding flow then uh we start on the billing page"
        let output = try #require(try engine.generate(input))
        let prompt = try engine.promptIDs(input), answer = engine.tokens(output) + [248_046]
        let ids = prompt + answer
        let h = trainer.hidden(Array(ids.dropLast()), trainer.lora)[(prompt.count - 1)...]
        let predicted = argMax(matmul(h.asType(.float16), trainer.embed.T), axis: -1).asArray(Int32.self)
        let agree = zip(predicted, answer).filter { $0 == $1 }.count
        print("trainer agrees on \(agree) of \(answer.count) tokens")
        #expect(agree == answer.count)
    }
}

@Suite struct FrozenWeightTests {
    /// int8 rows times a per-row scale, held in MLX's 8-bit affine format, give back the same weights.
    @Test func int8RowsRoundTripThroughMLXFormat() throws {
        let (rows, columns) = (3, 128)
        let d = (0..<(rows * columns)).map { Int8(truncatingIfNeeded: ($0 * 37) % 255 - 127) }
        let scale: [Float16] = [0.5, 0.01, 2]
        var blob = Data(count: 64)
        blob.append(d.withUnsafeBytes { Data($0) })
        let scaleOffset = blob.count
        blob.append(scale.withUnsafeBytes { Data($0) })
        let w = Trainer.frozen(blob, .init(shape: [rows, columns], weight: 64, scale: scaleOffset, loraA: 0, loraB: 0))
        let got = dequantized(w.q, scales: w.scales, biases: w.biases, groupSize: 64, bits: 8, dtype: .float32).asArray(Float.self)
        let want = d.indices.map { Float(d[$0]) * Float(scale[$0 / columns]) }
        #expect(zip(got, want).allSatisfy { abs($0 - $1) <= 1e-5 * max(1, abs($1)) })
    }
}

/// Trains on a cloned copy of the installed model, so it is skipped on a Mac without it.
@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: Cleaner.modelDirectory.appendingPathComponent("train.json").path)))
struct LearningTests {
    static let sentences = [
        "Can you send me the report by Friday?", "Let's move the standup to Thursday.", "Send it to Sarah.",
        "Remind me to call the dentist tomorrow at 9.", "The demo went well, but they want pricing first.",
        "We finish onboarding next week, then start on billing.", "Pick up groceries on the way home.",
        "Book a table for four at 7 on Saturday.", "The export bug only happens with large files.",
        "Ask Priya whether the contract is signed.", "I'll be about ten minutes late.",
        "Let's ship the beta on Monday and gather feedback.", "Please review the pull request before lunch.",
        "The new design looks great on mobile.", "Can we push the launch to next month?",
        "Tell Sam the build is green.", "We should order more coffee.", "Move the call to three.",
        "The invoice went out yesterday.", "Let's grab lunch after the review.",
    ]

    /// Made-up corrections from someone who never ends a message with punctuation, which the model always adds.
    static var pairs: [Cleaner.Pair] {
        sentences.map { target in
            let spoken = target.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" }
            return Cleaner.Pair(input: "um " + spoken, target: String(target.dropLast()))
        }
    }

    @Test func learnsAPersonalStyleAndKeepsIt() async throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("glide-learning-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: Cleaner.modelDirectory, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let cleaner = Cleaner(directory: copy)
        try await cleaner.prepare { _ in }
        let started = Date()
        let report = try #require(await cleaner.learn(from: Self.pairs, shouldStop: { false }))
        print("learned in \(Int(Date().timeIntervalSince(started))) s: held-out edits \(report.before) → \(report.after)")
        #expect(report.kept)
        #expect(await cleaner.clean("um tell sam the build is green") == "Tell Sam the build is green")
    }
}
