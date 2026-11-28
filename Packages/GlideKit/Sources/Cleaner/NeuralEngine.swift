import CoreML
import Foundation
import Tokenizers

/// The cleanup model as three Core ML programs (training/coreml/convert.py): two halves of 12 layers on the Neural Engine,
/// which keep the attention cache and the linear-attention state, and the greedy head on the GPU. The embedding is a row
/// read from `embed.bin`. Each call takes K tokens; greedy decoding checks the transcript's own tokens as guesses, K at a time.
final class NeuralEngine {
    static let K = 16, maxTokens = 512, width = 1024
    static let eos: Set<Int32> = [248_046, 248_044]
    /// The linear-attention state of each half. A rejected guess has already moved it, so it is saved around each guess.
    static let linear = [names(0..<9, "conv", "rec"), names(9..<18, "conv", "rec")]
    /// All state of each half, kept after the prompt opening every dictation shares.
    static let all = [names(0..<3, "k", "v") + linear[0], names(3..<6, "k", "v") + linear[1]]

    private let bodies: [MLModel]
    private let head: MLModel
    private let states: [MLState]
    private let embed: Data
    private let tokenizer: any Tokenizer
    private var prefix = 0
    private var cached: [[String: Data]] = []

    init(directory: URL) async throws {
        let ane = MLModelConfiguration(), gpu = MLModelConfiguration()
        ane.computeUnits = .cpuAndNeuralEngine
        gpu.computeUnits = .cpuAndGPU
        var bodies: [MLModel] = []
        for name in ["body0", "body1"] {
            bodies.append(try await MLModel.load(contentsOf: try await Self.compiled(name, in: directory), configuration: ane))
        }
        self.bodies = bodies
        head = try await MLModel.load(contentsOf: try await Self.compiled("head", in: directory), configuration: gpu)
        states = bodies.map { $0.makeState() }
        embed = try Data(contentsOf: directory.appendingPathComponent("embed.bin"), options: .alwaysMapped)
        tokenizer = try await AutoTokenizer.from(modelFolder: directory)

        // The system prompt and the user turn's opening run once; every dictation starts from their state.
        let a = try promptIDs("a"), b = try promptIDs("b")
        prefix = zip(a, b).prefix { $0 == $1 }.count
        _ = try run(Array(a[..<prefix]), at: 0)
        cached = snapshot(Self.all)
    }

    /// Greedy cleanup of `text`, nil when the prompt and the longest allowed reply don't fit in the cache.
    func generate(_ text: String, speculate: Bool = true) throws -> String? {
        let ids = try promptIDs(text)
        let draft = tokenizer.encode(text: text, addSpecialTokens: false).map(Int32.init)
        // Room for numbers and punctuation, never for an essay.
        let budget = 2 * draft.count + 50
        // shortcut: about 95 words fit in 512 positions, longer dictations go out as transcribed; reconvert with a larger MAX when that matters.
        guard ids.count + budget + Self.K <= Self.maxTokens else { return nil }
        restore(cached)
        var next = try run(Array(ids[prefix...]), at: prefix).last!
        let keys = draft.map(key)
        var out: [Int32] = [], pos = ids.count
        while !Self.eos.contains(next), out.count < budget {
            out.append(next)
            // Guess that the reply continues like the transcript does after the longest recent run of output found in it,
            // compared without case or punctuation, so "Um," matches "um".
            var guess: [Int32] = []
            if speculate {
                let tail = out.suffix(4).map(key)
                for back in stride(from: tail.count, to: 0, by: -1) where keys.count >= back {
                    let want = Array(tail.suffix(back))
                    if let hit = (0...(keys.count - back)).first(where: { Array(keys[$0..<($0 + back)]) == want }) {
                        guess = Array(draft[(hit + back)..<min(hit + back + Self.K - 1, draft.count)])
                        break
                    }
                }
            }
            let feed = [next] + guess
            let saved = guess.isEmpty ? [] : snapshot(Self.linear)
            var predicted = try run(feed, at: pos)
            var agreed = 0
            while agreed < guess.count, predicted[agreed] == guess[agreed] { agreed += 1 }
            if agreed < guess.count {
                restore(saved)
                predicted = try run(Array(feed[...agreed]), at: pos)
            }
            out += guess[..<agreed]
            pos += agreed + 1
            next = predicted[agreed]
        }
        return tokenizer.decode(tokens: out.filter { !Self.eos.contains($0) }.map(Int.init), skipSpecialTokens: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func promptIDs(_ text: String) throws -> [Int32] {
        try tokenizer.applyChatTemplate(
            messages: [["role": "system", "content": Cleaner.system], ["role": "user", "content": text]],
            tools: nil, additionalContext: ["enable_thinking": false]
        ).map(Int32.init)
    }

    private func key(_ token: Int32) -> String {
        String(tokenizer.decode(tokens: [Int(token)], skipSpecialTokens: false).lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Feeds `tokens` at positions `start...`, K at a time; the greedy next token after each.
    func run(_ tokens: [Int32], at start: Int) throws -> [Int32] {
        var out: [Int32] = []
        for i in stride(from: 0, to: tokens.count, by: Self.K) {
            let chunk = Array(tokens[i..<min(i + Self.K, tokens.count)])
            let positions = chunk.indices.map { start + i + $0 } + Array(repeating: start + i + chunk.count - 1, count: Self.K - chunk.count)
            out += try step(chunk, positions: positions)
        }
        return out
    }

    private func step(_ chunk: [Int32], positions: [Int]) throws -> [Int32] {
        let K = Self.K, n = chunk.count, rowBytes = Self.width * 2
        let x = try MLMultiArray(shape: [K, Self.width].map { NSNumber(value: $0) }, dataType: .float16)
        x.withUnsafeMutableBytes { out, _ in
            embed.withUnsafeBytes { rows in
                for (i, token) in (chunk + Array(repeating: 0, count: K - n)).enumerated() {
                    (out.baseAddress! + i * rowBytes).copyMemory(from: rows.baseAddress! + Int(token) * rowBytes, byteCount: rowBytes)
                }
            }
        }
        let i = Self.inputs(positions: positions, active: n, K: K, max: Self.maxTokens)
        let fixed: [String: MLFeatureValue] = [
            "cos": .init(multiArray: try Self.half(i.cos, [K, 64])), "sin": .init(multiArray: try Self.half(i.sin, [K, 64])),
            "mask": .init(multiArray: try Self.half(i.mask, [K, Self.maxTokens])),
            "write": .init(multiArray: try Self.half(i.write, [Self.maxTokens, K])),
            "active": .init(multiArray: try Self.half(i.active, [K])), "pick": .init(multiArray: try Self.half(i.pick, [3, 3 + K])),
        ]
        var h = x
        for (body, state) in zip(bodies, states) {
            var features = fixed
            features["x"] = .init(multiArray: h)
            guard let next = try body.prediction(from: MLDictionaryFeatureProvider(dictionary: features), using: state)
                .featureValue(for: "h")?.multiArrayValue else { throw EngineError.output("h") }
            h = next
        }
        guard let next = try head.prediction(from: MLDictionaryFeatureProvider(dictionary: ["h": MLFeatureValue(multiArray: h)]))
            .featureValue(for: "next")?.multiArrayValue else { throw EngineError.output("next") }
        return (0..<n).map { next[[0, NSNumber(value: $0)]].int32Value }
    }

    func snapshot(_ names: [[String]]) -> [[String: Data]] {
        zip(states, names).map { state, names in
            Dictionary(uniqueKeysWithValues: names.map { name in
                (name, state.withMultiArray(for: name) { array in array.withUnsafeBytes { Data($0) } })
            })
        }
    }

    func restore(_ saved: [[String: Data]]) {
        for (state, values) in zip(states, saved) {
            for (name, data) in values {
                state.withMultiArray(for: name) { array in array.withUnsafeMutableBytes { out, _ in _ = data.copyBytes(to: out) } }
            }
        }
    }

    /// What depends on positions, as training/coreml/qwen35.py's inputs_for builds it: rotary angles, the attention mask,
    /// where each token's key and value go, which tokens are real, and which conv inputs become the next conv state.
    struct Inputs: Equatable {
        var cos: [Float], sin: [Float], mask: [Float], write: [Float], active: [Float], pick: [Float]
    }

    static func inputs(positions: [Int], active n: Int, K: Int, max: Int, ropeDim: Int = 64, theta: Double = 1e7) -> Inputs {
        let half = ropeDim / 2
        var i = Inputs(cos: [], sin: [], mask: Array(repeating: -1e4, count: K * max), write: Array(repeating: 0, count: max * K),
                       active: (0..<K).map { $0 < n ? 1 : 0 }, pick: Array(repeating: 0, count: 3 * (3 + K)))
        for p in positions {
            let angles = (0..<half).map { Double(p) / pow(theta, Double(2 * $0) / Double(ropeDim)) }
            i.cos += Array(repeating: angles.map { Float(Foundation.cos($0)) }, count: 2).joined()
            i.sin += Array(repeating: angles.map { Float(Foundation.sin($0)) }, count: 2).joined()
        }
        for t in 0..<n { i.write[positions[t] * K + t] = 1 }
        for t in 0..<K {
            let upto = n > 0 ? positions[min(t, n - 1)] : 0
            for j in 0...upto { i.mask[t * max + j] = 0 }
        }
        for r in 0..<3 { i.pick[r * (3 + K) + n + r] = 1 }
        return i
    }

    private static func half(_ values: [Float], _ shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
        array.withUnsafeMutableBufferPointer(ofType: Float16.self) { out, _ in
            for (j, v) in values.enumerated() { out[j] = Float16(v) }
        }
        return array
    }

    /// Compiles a downloaded package once and keeps the result next to it.
    private static func compiled(_ name: String, in directory: URL) async throws -> URL {
        let target = directory.appendingPathComponent("compiled/\(name).mlmodelc")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let temporary = try await MLModel.compileModel(at: directory.appendingPathComponent("\(name).mlpackage"))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Swapped in whole, so a load racing this one finds either no folder or a complete one.
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        return target
    }

    private static func names(_ layers: Range<Int>, _ a: String, _ b: String) -> [String] {
        layers.flatMap { ["\(a)\($0)", "\(b)\($0)"] }
    }

    enum EngineError: Error { case output(String) }
}
