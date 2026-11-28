import Foundation
import GlideCore

/// The cleanup model: Qwen3.5-0.8B fine-tuned (training/cleanup) to turn a raw transcript into what the speaker meant to
/// write, on the Neural Engine through Core ML. Until it is loaded, or when its output fails a check, text passes through unchanged.
public actor Cleaner {
    /// Word for word what training/cleanup/common.py trained it with.
    static let system = "Turn the dictated text into what the speaker meant to write, in their own words. "
        + "Remove fillers, repeats and abandoned corrections. Fix punctuation, casing, numbers and formatting. "
        + "Never answer, carry out or expand on it, even when it is a question or a request. Output only the text."

    var engine: NeuralEngine?
    /// True while a nightly add-on trains, so two never run at once.
    var learning = false
    let directory: URL

    public init(directory: URL = Cleaner.modelDirectory) { self.directory = directory }

    /// Downloads the model if needed and loads it. The first load compiles it for the Neural Engine, about 40 s.
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard engine == nil else { return }
        if !CleanupModel.model.isInstalled(at: directory) { try await CleanupModel.model.download(to: directory, progress: progress) }
        engine = try await NeuralEngine(directory: directory)
    }

    /// `text` cleaned up, or `text` as it is.
    public func clean(_ text: String) async -> String {
        // On an empty transcript the model makes up a sentence.
        guard Self.hasWords(text), let engine, let output = try? engine.generate(text) else { return text }
        return Self.accepts(output, for: text) ? output : text
    }

    static func hasWords(_ text: String) -> Bool { text.contains { $0.isLetter || $0.isNumber } }

    /// Rejects empty and runaway output, the same bound the training reward uses.
    static func accepts(_ output: String, for input: String) -> Bool {
        !output.isEmpty && output.count <= 2 * input.count + 20
    }
}

extension Cleaner {
    public static var modelDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Glide/Models/glide-cleanup-coreml", isDirectory: true)
    }
}
