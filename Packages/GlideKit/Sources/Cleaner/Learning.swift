import Foundation

/// Nightly personal tuning: a LoRA add-on trained on the user's own corrections, on this Mac only, then written into the
/// Neural Engine packages.
extension Cleaner {
    /// A transcript and the text the user kept for it.
    public struct Pair: Sendable {
        public let input: String
        public let target: String
        public init(input: String, target: String) { (self.input, self.target) = (input, target) }
    }

    /// Word edits from the model's output to the kept text, summed over the held-out pairs.
    public struct Report: Sendable {
        public let trained: Int
        public let heldOut: Int
        public let before: Int
        public let after: Int
        public var kept: Bool { after < before }
    }

    static let epochs = 5
    /// 1e-3 and 1e-4 diverge with an add-on in every layer (training/README.md, training probe).
    static let learningRate: Float = 2e-5

    /// Trains a fresh add-on on `pairs` and keeps it only if it beats the current model on held-out pairs, so a bad
    /// night changes nothing. Nil when the model isn't loaded, there's too little to learn from, or `shouldStop` cut
    /// training short.
    public func learn(from pairs: [Pair], shouldStop: @escaping @Sendable () -> Bool) async -> Report? {
        guard let engine, !learning else { return nil }
        learning = true
        defer { learning = false }
        let (train, heldOut) = Self.split(pairs)
        guard !train.isEmpty, !heldOut.isEmpty else { return nil }
        let staging = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".learning")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            let before = try Self.edits(heldOut, engine)
            let examples = try train.map { (prompt: try engine.promptIDs($0.input), answer: engine.tokens($0.target + "<|im_end|>")) }
            // In its own scope so the trainer's weights are freed before the tuned model compiles and loads.
            do {
                let trainer = try Trainer(directory: directory)
                guard await trainer.train(on: examples, epochs: Self.epochs, learningRate: Self.learningRate, shouldStop: shouldStop) else {
                    return nil
                }
                // A copy of the model (APFS clones it, so it costs no space until written) with the add-on in its bodies.
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.copyItem(at: directory, to: staging)
                for half in ["body0", "body1"] {
                    try FileManager.default.removeItem(at: staging.appendingPathComponent("compiled/\(half).mlmodelc"))
                }
                try trainer.write(to: staging)
            }
            Trainer.releaseMemory()
            let tuned = try await NeuralEngine(directory: staging)
            let report = Report(trained: train.count, heldOut: heldOut.count, before: before, after: try Self.edits(heldOut, tuned))
            guard report.kept else { return report }
            _ = try FileManager.default.replaceItemAt(directory, withItemAt: staging)
            self.engine = tuned
            return report
        } catch {
            return nil
        }
    }

    /// Every fifth pair, oldest first, is held out to judge the new add-on.
    static func split(_ pairs: [Pair]) -> (train: [Pair], heldOut: [Pair]) {
        let held = pairs.indices.filter { $0 % 5 == 4 }
        return (pairs.indices.filter { $0 % 5 != 4 }.map { pairs[$0] }, held.map { pairs[$0] })
    }

    static func edits(_ pairs: [Pair], _ engine: NeuralEngine) throws -> Int {
        try pairs.reduce(0) { total, pair in
            let output = try engine.generate(pair.input)
            return total + wordEdits(output.flatMap { accepts($0, for: pair.input) ? $0 : nil } ?? pair.input, pair.target)
        }
    }

    /// Edit distance over whitespace-split words, so punctuation and case count.
    static func wordEdits(_ a: String, _ b: String) -> Int {
        let a = a.split(whereSeparator: \.isWhitespace), b = b.split(whereSeparator: \.isWhitespace)
        var row = Array(0...b.count)
        for i in stride(from: 1, through: a.count, by: 1) {
            var diagonal = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                (diagonal, row[j]) = (row[j], min(row[j] + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
        }
        return row[b.count]
    }
}
