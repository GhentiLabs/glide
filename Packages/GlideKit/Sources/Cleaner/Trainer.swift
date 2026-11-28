import Foundation
import MLX

/// Trains a LoRA add-on for the cleanup model on the GPU with MLX, over the very int8 weights the Neural Engine runs:
/// `train.json` (training/coreml/export_train.py) says where each projection's rows and scales sit in the packages'
/// weight.bin. The forward pass is training/coreml/qwen35.py over whole sequences, with the chunked gated delta rule
/// (as in train_probe.py), so every layer has a gradient. The result is written into the packages' LoRA slots.
final class Trainer {
    struct Config: Decodable {
        let layers: [Layer]
        let rank, heads, kvHeads, headDim, linearHeads, linearKeyHeads, keyDim, valueDim: Int
        let eps: Float
    }

    struct Layer: Decodable {
        let type: String
        let part: Int
        let proj: [String: Projection]
        var isAttention: Bool { type == "full_attention" }
    }

    struct Projection: Decodable {
        let shape: [Int]
        let weight, scale, loraA, loraB: Int
    }

    /// One int8 projection as MLX's 8-bit affine format: a row's scale repeated per group of 64, bias -128 × scale.
    struct Frozen {
        let q, scales, biases: MLXArray
    }

    static let chunk = 16, scale: Float = 10, ropeDim = 64, theta = 1e7

    let config: Config
    private let frozen: [[String: Frozen]]
    private let small: [String: MLXArray]
    let embed: MLXArray
    /// The add-on's A and B for each (layer, projection) in `slots` order, trained in fp32.
    private(set) var lora: [MLXArray]
    let slots: [(layer: Int, name: String)]

    init(directory: URL) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config = try decoder.decode(Config.self, from: Data(contentsOf: directory.appendingPathComponent("train.json")))
        self.config = config
        let weights = try (0..<2).map {
            try Data(contentsOf: directory.appendingPathComponent("body\($0).mlpackage/Data/com.apple.CoreML/weights/weight.bin"), options: .alwaysMapped)
        }
        frozen = config.layers.map { layer in
            layer.proj.mapValues { Self.frozen(weights[layer.part], $0) }
        }
        small = try loadArrays(url: directory.appendingPathComponent("train.safetensors"))
        let rows = try Data(contentsOf: directory.appendingPathComponent("embed.bin"), options: .alwaysMapped)
        embed = MLXArray(rows, [rows.count / (2 * 1024), 1024], type: Float16.self)
        let slots = config.layers.enumerated().flatMap { i, layer in layer.proj.keys.sorted().map { (layer: i, name: $0) } }
        self.slots = slots
        // A as MLX's LoRA starts it, B at zero, so training starts from the model as it is.
        lora = slots.flatMap { slot -> [MLXArray] in
            let shape = config.layers[slot.layer].proj[slot.name]!.shape
            let bound = 1 / Float(shape[1]).squareRoot()
            return [MLX.uniform(low: -bound, high: bound, [config.rank, shape[1]]), MLXArray.zeros([shape[0], config.rank])]
        }
    }

    static func frozen(_ blob: Data, _ p: Projection) -> Frozen {
        let (rows, columns) = (p.shape[0], p.shape[1])
        // MLX packs four 8-bit values to a uint32, element j in bits 8j, which is the bytes' own order. Flipping each byte's
        // top bit turns int8 d into the uint8 d + 128 it expects.
        let raw = MLXArray(blob.subdata(in: p.weight..<(p.weight + rows * columns)), [rows, columns / 4], type: UInt32.self)
        let q = raw ^ MLXArray(UInt32(0x8080_8080))
        let rowScale = MLXArray(blob.subdata(in: p.scale..<(p.scale + 2 * rows)), [rows, 1], type: Float16.self).asType(.float32)
        let scales = MLX.repeated(rowScale, count: columns / 64, axis: 1)
        return Frozen(q: q, scales: scales, biases: scales * -128)
    }

    // MARK: Forward

    /// Hidden states after the final norm for `ids`, [T, 1024].
    func hidden(_ ids: [Int32], _ lora: [MLXArray]) -> MLXArray {
        let T = ids.count
        var x = embed[MLXArray(ids)].asType(.float32)
        let (cos, sin) = Self.rope(T)
        let causal = MLX.triu(MLXArray.full([T, T], values: MLXArray(Float(-1e9))), k: 1)
        var slot = 0
        for (i, layer) in config.layers.enumerated() {
            var adapters: [String: (MLXArray, MLXArray)] = [:]
            for name in layer.proj.keys.sorted() {
                adapters[name] = (lora[2 * slot], lora[2 * slot + 1])
                slot += 1
            }
            let project = { (name: String, h: MLXArray) -> MLXArray in
                let w = self.frozen[i][name]!, (a, b) = adapters[name]!
                return quantizedMatmul(h, w.q, scales: w.scales, biases: w.biases, transpose: true, groupSize: 64, bits: 8)
                    + matmul(matmul(h, a.T), b.T) * Self.scale
            }
            let p = "layers.\(i)."
            var h = rms(x, small[p + "ln1"]!)
            x = x + (layer.isAttention ? attention(h, project, p, cos, sin, causal) : linearAttention(h, project, p))
            h = rms(x, small[p + "ln2"]!)
            x = x + project("down_proj", silu(project("gate_proj", h)) * project("up_proj", h))
        }
        return rms(x, small["norm"]!)
    }

    /// Mean cross-entropy of `answer` after `prompt`, from the tied embedding as the head, on the answer positions only.
    func loss(prompt: [Int32], answer: [Int32], _ lora: [MLXArray]) -> MLXArray {
        let ids = prompt + answer
        let h = hidden(Array(ids.dropLast()), lora)[(prompt.count - 1)...]
        let logits = matmul(h.asType(.float16), embed.T).asType(.float32)
        let targets = MLXArray(answer).reshaped(-1, 1)
        return (logSumExp(logits, axis: -1) - takeAlong(logits, targets, axis: -1).squeezed(axis: -1)).mean()
    }

    private func attention(_ x: MLXArray, _ project: (String, MLXArray) -> MLXArray, _ p: String,
                           _ cos: MLXArray, _ sin: MLXArray, _ causal: MLXArray) -> MLXArray {
        let T = x.dim(0), hd = config.headDim, H = config.heads, kvH = config.kvHeads
        let qg = project("q_proj", x).reshaped(T, H, 2 * hd)
        var q = rms(qg[0..., 0..., ..<hd], small[p + "q_norm"]!).transposed(1, 0, 2)
        let gate = qg[0..., 0..., hd...]
        var k = rms(project("k_proj", x).reshaped(T, kvH, hd), small[p + "k_norm"]!).transposed(1, 0, 2)
        var v = project("v_proj", x).reshaped(T, kvH, hd).transposed(1, 0, 2)
        let r = Self.ropeDim
        let rope = { (t: MLXArray) -> MLXArray in
            let t1 = t[0..., 0..., ..<(r / 2)], t2 = t[0..., 0..., (r / 2)..<r]
            return concatenated([t1 * cos[0..., ..<(r / 2)] - t2 * sin[0..., ..<(r / 2)],
                                 t2 * cos[0..., (r / 2)...] + t1 * sin[0..., (r / 2)...], t[0..., 0..., r...]], axis: -1)
        }
        q = rope(q)
        k = MLX.repeated(rope(k), count: H / kvH, axis: 0)
        v = MLX.repeated(v, count: H / kvH, axis: 0)
        let att = softmax(matmul(q, k.transposed(0, 2, 1)) / Float(hd).squareRoot() + causal, axis: -1)
        let out = matmul(att, v).transposed(1, 0, 2).reshaped(T, -1) * sigmoid(gate.reshaped(T, -1))
        return project("o_proj", out)
    }

    private func linearAttention(_ x: MLXArray, _ project: (String, MLXArray) -> MLXArray, _ p: String) -> MLXArray {
        let T = x.dim(0), vh = config.linearHeads, kh = config.linearKeyHeads, dk = config.keyDim, dv = config.valueDim
        let qkv = project("in_proj_qkv", x)
        let z = project("in_proj_z", x).reshaped(T, vh, dv)
        let beta = sigmoid(matmul(x, small[p + "in_proj_b"]!.T))
        let logDecay = small[p + "A"]! * logAddExp(matmul(x, small[p + "in_proj_a"]!.T) + small[p + "dt_bias"]!, MLXArray(Float(0)))
        // Causal depthwise conv over 4 taps, zeros before the first token.
        let w = small[p + "conv"]!
        let input = concatenated([MLXArray.zeros([3, qkv.dim(1)]), qkv], axis: 0)
        let conv = silu((0..<4).map { input[$0..<($0 + T)] * w[0..., $0] }.reduce(MLXArray(Float(0)), +))
        let kd = kh * dk
        var q = conv[0..., ..<kd].reshaped(T, kh, dk), k = conv[0..., kd..<(2 * kd)].reshaped(T, kh, dk)
        let v = conv[0..., (2 * kd)...].reshaped(T, vh, dv)
        q = q * rsqrt((q * q).sum(axis: -1, keepDims: true) + 1e-6) / Float(dk).squareRoot()
        k = k * rsqrt((k * k).sum(axis: -1, keepDims: true) + 1e-6)
        if vh != kh {
            q = MLX.repeated(q, count: vh / kh, axis: 1)
            k = MLX.repeated(k, count: vh / kh, axis: 1)
        }
        let core = Self.chunkedDelta(q, k, v, logDecay, beta)
        return project("out_proj", (rms(core, small[p + "gnorm"]!, centered: false) * silu(z)).reshaped(T, -1))
    }

    /// The gated delta rule from a zero state, a chunk of 16 tokens at a time (UT/WY form). q, k [T, H, Dk]; v [T, H, Dv];
    /// logDecay, beta [T, H]. Longer chunks lose fp32 precision on heads with strong decay.
    static func chunkedDelta(_ q: MLXArray, _ k: MLXArray, _ v: MLXArray, _ logDecay: MLXArray, _ beta: MLXArray) -> MLXArray {
        let T = q.dim(0), H = q.dim(1), Dk = q.dim(2), Dv = v.dim(2), C = chunk
        let pad = (C - T % C) % C, N = (T + pad) / C
        // Padding has zero k, v and beta and log decay 0, so it leaves the state alone.
        let chunks = { (t: MLXArray) -> MLXArray in
            let padded = padded(t, widths: [.init((0, pad))] + Array(repeating: .init((0, 0)), count: t.ndim - 1))
            return t.ndim == 3 ? padded.transposed(1, 0, 2).reshaped(H, N, C, -1) : padded.transposed(1, 0).reshaped(H, N, C)
        }
        let (qc, kc, vc, g, b) = (chunks(q), chunks(k), chunks(v), chunks(logDecay), chunks(beta))
        let c = cumsum(g, axis: -1)
        let lower = tril(MLXArray.ones([C, C]), k: -1), eye = MLX.eye(C), causal = tril(MLXArray.ones([C, C]))
        let decay = exp(minimum(expandedDimensions(c, axis: -1) - expandedDimensions(c, axis: -2), 0)) * lower
        let kb = kc * expandedDimensions(b, axis: -1)
        let A = matmul(kb, kc.swappedAxes(-1, -2)) * decay
        // (I + A)^-1 for strictly lower A: (I - A)(I + A²)(I + A⁴)(I + A⁸)
        var inverse = eye - A, power = matmul(A, A)
        for _ in 0..<(C.bitWidth - C.leadingZeroBitCount - 2) {
            inverse = matmul(inverse, eye + power)
            power = matmul(power, power)
        }
        let u = matmul(inverse, vc * expandedDimensions(b, axis: -1))
        let w = matmul(inverse, kb * expandedDimensions(exp(c), axis: -1))
        let qk = matmul(qc, kc.swappedAxes(-1, -2)) * (decay + eye) * causal
        var S = MLXArray.zeros([H, Dv, Dk])
        var out: [MLXArray] = []
        for n in 0..<N {
            let St = S.swappedAxes(-1, -2)
            let vNew = u[0..., n] - matmul(w[0..., n], St)
            out.append(matmul(qc[0..., n] * expandedDimensions(exp(c[0..., n]), axis: -1), St) + matmul(qk[0..., n], vNew))
            let last = c[0..., n, (C - 1)...]
            let kd = kc[0..., n] * expandedDimensions(exp(last - c[0..., n]), axis: -1)
            S = S * expandedDimensions(exp(last), axis: -1) + matmul(kd.swappedAxes(-1, -2), vNew).swappedAxes(-1, -2)
        }
        return stacked(out, axis: 1).reshaped(H, N * C, Dv)[0..., ..<T].transposed(1, 0, 2)
    }

    private func rms(_ x: MLXArray, _ w: MLXArray, centered: Bool = true) -> MLXArray {
        let normed = x * rsqrt((x * x).mean(axis: -1, keepDims: true) + config.eps)
        return normed * (centered ? 1 + w : w)
    }

    private func silu(_ x: MLXArray) -> MLXArray { x * sigmoid(x) }

    private static func rope(_ T: Int) -> (MLXArray, MLXArray) {
        let half = ropeDim / 2
        let angles = (0..<T).flatMap { p in (0..<half).map { Double(p) / pow(theta, Double(2 * $0) / Double(ropeDim)) } }
        let cos = MLXArray(angles.map { Float(Foundation.cos($0)) }).reshaped(T, half)
        let sin = MLXArray(angles.map { Float(Foundation.sin($0)) }).reshaped(T, half)
        return (concatenated([cos, cos], axis: -1), concatenated([sin, sin], axis: -1))
    }

    // MARK: Training

    /// Adam over the add-on, one example a step. False when `shouldStop` cut it short.
    func train(on examples: [(prompt: [Int32], answer: [Int32])], epochs: Int, learningRate: Float,
               shouldStop: () -> Bool) async -> Bool {
        // Uncapped, MLX keeps every freed buffer for reuse and grows by gigabytes over a run.
        Memory.cacheLimit = 512 * 1024 * 1024
        var m = lora.map { MLXArray.zeros(like: $0) }, v = m
        let (b1, b2, eps): (Float, Float, Float) = (0.9, 0.999, 1e-8)
        var t = 0
        for _ in 0..<epochs {
            for example in examples.shuffled() {
                if shouldStop() { return false }
                t += 1
                let step = valueAndGrad({ [self] in [loss(prompt: example.prompt, answer: example.answer, $0)] }, argumentNumbers: Array(lora.indices))
                let (_, grads) = step(lora)
                let (c1, c2) = (1 - pow(b1, Float(t)), 1 - pow(b2, Float(t)))
                for i in lora.indices {
                    m[i] = b1 * m[i] + (1 - b1) * grads[i]
                    v[i] = b2 * v[i] + (1 - b2) * grads[i] * grads[i]
                    lora[i] = lora[i] - learningRate * (m[i] / c1) / (sqrt(v[i] / c2) + eps)
                }
                eval(lora + m + v)
                await Task.yield()
            }
        }
        return true
    }

    /// Hands MLX's cached buffers back to the system once training is over.
    static func releaseMemory() { Memory.clearCache() }

    /// Writes the add-on into the LoRA slots of `directory`'s body packages, B pre-multiplied by the scale. Only the slots
    /// change, so the packages keep their size.
    func write(to directory: URL) throws {
        let handles = try (0..<2).map {
            try FileHandle(forWritingTo: directory.appendingPathComponent("body\($0).mlpackage/Data/com.apple.CoreML/weights/weight.bin"))
        }
        defer { handles.forEach { try? $0.close() } }
        for (j, slot) in slots.enumerated() {
            let layer = config.layers[slot.layer], p = layer.proj[slot.name]!
            for (offset, value) in [(p.loraA, lora[2 * j]), (p.loraB, lora[2 * j + 1] * Self.scale)] {
                let half = value.asType(.float16).asArray(Float16.self)
                try handles[layer.part].seek(toOffset: UInt64(offset))
                try handles[layer.part].write(contentsOf: half.withUnsafeBytes { Data($0) })
            }
        }
    }
}
