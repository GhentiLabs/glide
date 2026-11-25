import CryptoKit
import Foundation

/// Fluid Speech Pro's Core ML build: Parakeet TDT 0.6B v3 post-trained by FluidVoice, 8-bit encoder, 652 MB.
/// Downloaded from one pinned revision, and every file is checked against the hash recorded here before it is used.
/// FluidAudio has no download for it, so Glide fetches it and loads it as a local v3-family model.
enum FluidSpeechPro {
    static let repo = "FluidVoice-Labs/fluid-speech-pro-coreml"
    static let revision = "3b9d38a93d606f84011e5a0a669b7ea146375a22"
    /// The license asks for this line wherever the model is credited.
    static let attribution = "Fluid Speech Pro by FluidVoice. Built on NVIDIA Parakeet TDT 0.6B v3 and Moondream Parakeet Ultra."

    enum Hash: Sendable {
        /// SHA-256 of the contents, for files stored with Git LFS.
        case sha256(String)
        /// Git's blob id (SHA-1 of a header and the contents), for small files kept in Git itself.
        case blob(String)
    }

    struct File: Sendable {
        let path: String
        let size: Int64
        let hash: Hash
        init(_ path: String, _ size: Int64, _ hash: Hash) { (self.path, self.size, self.hash) = (path, size, hash) }

        /// FluidAudio's v3 decoder looks for the joint under its v3 name; the contract is the same, minus outputs it reads
        /// only when a language is forced, which Glide never does.
        var localPath: String { path.replacingOccurrences(of: "JointDecision.mlmodelc", with: "JointDecisionv3.mlmodelc") }
    }

    static let files: [File] = [
        File("Decoder.mlmodelc/analytics/coremldata.bin", 243, .sha256("d172cb80cbf3a2cd768952557164db1b50b9c6aef16af3653d2fd7c03d9fe8e5")),
        File("Decoder.mlmodelc/coremldata.bin", 491, .sha256("5059c27aa8cc44eb735247d335e18da599d15e30d67b3d2d5633679fc5806f8a")),
        File("Decoder.mlmodelc/metadata.json", 3311, .blob("1482a1a62db32d0b522ad81d8ad61ef508c66a07")),
        File("Decoder.mlmodelc/model.mil", 11823, .blob("b700a32d142e23373ddba8bc62bc59b4bb225972")),
        File("Decoder.mlmodelc/weights/weight.bin", 23604992, .sha256("7b3e3a4e3fbb580ae990613915f8ea2309226d85999ae37120912b8352d1df9e")),
        File("Encoder.mlmodelc/analytics/coremldata.bin", 243, .sha256("ac53d09c1b1f7f00fd1a07a630d57c4193089b19fe0d3b1571a3ecf91be62aa4")),
        File("Encoder.mlmodelc/coremldata.bin", 427, .sha256("abfbc09cc0b8aba7911e38390390f1c5850e3665862238035052e015659ebb74")),
        File("Encoder.mlmodelc/metadata.json", 2758, .blob("d5f938d2b7e856b56922ff432b42ad8c8cade547")),
        File("Encoder.mlmodelc/model.mil", 621903, .blob("85ca4b717730654988681884c0323cb91b921222")),
        File("Encoder.mlmodelc/weights/weight.bin", 613088448, .sha256("4abdc3b4af2ff9b2843105f29677f0e674d2b08638b1ce6feac60876c235c659")),
        File("JointDecision.mlmodelc/analytics/coremldata.bin", 243, .sha256("3dd0d66c51f69d683c587d5c88f3256d5e1690105ecf9d8ca4b0c2b8e1c883c7")),
        File("JointDecision.mlmodelc/coremldata.bin", 462, .sha256("febdb37a5ad1a119539c33cf68fac1c51f80f40f82c90b6ef312033191ff4063")),
        File("JointDecision.mlmodelc/metadata.json", 2728, .blob("278595041fe63406e9bac1ee0549ca8e6ce6bee7")),
        File("JointDecision.mlmodelc/model.mil", 7178, .blob("878d53f9821e589d09ca40997152f30ee71b4fd1")),
        File("JointDecision.mlmodelc/weights/weight.bin", 12642764, .sha256("f0939e8807dded497926a7c3634af698557ec8b155d804f8f40e367e97f90849")),
        File("Preprocessor.mlmodelc/analytics/coremldata.bin", 243, .sha256("886396da81b6b29d60d79d903bd5d1f00077a7a4323f40cd2e9214d4205d8e6b")),
        File("Preprocessor.mlmodelc/coremldata.bin", 429, .sha256("38f130eac9ffde8c684043d76e3eecdd3b6f9564d9efa59f7a87a34a272a4901")),
        File("Preprocessor.mlmodelc/metadata.json", 2606, .blob("659c015605b1d1267b0b695fd7dec44c092252ea")),
        File("Preprocessor.mlmodelc/model.mil", 11891, .blob("049c2ecc5a046a5762b7db00225d56dcf5a041f7")),
        File("Preprocessor.mlmodelc/weights/weight.bin", 2150580, .sha256("44180071e400951080786feb46452bffc4fb26363a703655ebadb760c8ad4030")),
        File("parakeet_vocab.json", 151122, .blob("c684822ec3b671ebc449c433a7012398d39b8bb0")),
    ]

    enum DownloadError: LocalizedError {
        case badResponse(String, Int)
        case checksum(String)
        var errorDescription: String? {
            switch self {
            case .badResponse(let file, let status): "Downloading \(file) failed with HTTP \(status)."
            case .checksum(let file): "\(file) didn't match its recorded checksum."
            }
        }
    }

    /// True when every file is in place. Sizes only: hashes were checked when the files were downloaded.
    static func isInstalled(at directory: URL) -> Bool {
        files.allSatisfy { file in
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file.localPath).path)[.size]) as? Int64
            return size == file.size
        }
    }

    /// Downloads into a staging folder, keeping files already verified there, and moves it into place only when complete.
    static func download(to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let staging = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".partial")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = Double(files.reduce(0) { $0 + $1.size })
        var done: Int64 = 0
        for file in files {
            let target = staging.appendingPathComponent(file.localPath)
            if (try? matches(target, file)) == true {
                done += file.size
                continue
            }
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
            let base = done
            let fetched = try await fetch(url, name: file.path) { progress((Double(base) + Double($0)) / total) }
            guard try matches(fetched, file) else {
                try? fm.removeItem(at: fetched)
                throw DownloadError.checksum(file.path)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: fetched, to: target)
            done += file.size
            progress(Double(done) / total)
        }
        try? fm.removeItem(at: directory)
        try fm.moveItem(at: staging, to: directory)
    }

    static func matches(_ url: URL, _ file: File) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        switch file.hash {
        case .sha256(let expected):
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hex(hasher.finalize()) == expected
        case .blob(let expected):
            let data = try handle.readToEnd() ?? Data()
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(data.count)\0".utf8))
            hasher.update(data: data)
            return hex(hasher.finalize()) == expected
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// One file to a temporary location, reporting bytes received.
    private static func fetch(_ url: URL, name: String, received: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
                    if let error { return continuation.resume(throwing: error) }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard let temp, status == 200 else { return continuation.resume(throwing: DownloadError.badResponse(name, status)) }
                    // The system deletes `temp` when this handler returns.
                    let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: temp, to: kept)
                        continuation.resume(returning: kept)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.task = task
                task.resume()
                Task {
                    while task.state == .running {
                        received(task.countOfBytesReceived)
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionDownloadTask?
    }
}
