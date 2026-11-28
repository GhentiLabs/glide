import Foundation
import FluidAudio
import GlideCore

/// Fluid Speech Pro on Core ML, through FluidAudio's Parakeet v3 decoder.
public actor SpeechRecognizer: GlideCore.Recognizer {
    private var manager: AsrManager?
    private let directory: URL
    /// A separate 110M CTC model that checks vocabulary words against the audio. Downloaded once the vocabulary has a word.
    private var ctcLoad: Task<CtcModels, Error>?
    private var boosting: VocabularyBoostingSession?
    private var vocabularyVersion = 0

    public init(directory: URL = SpeechRecognizer.modelDirectory) { self.directory = directory }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        if !FluidSpeechPro.model.isInstalled(at: directory) {
            // Downloading is most of the wait; loading for the Neural Engine takes the rest the first time.
            try await FluidSpeechPro.model.download(to: directory) { progress(0.95 * $0) }
        }
        // Same contract as Parakeet Ultra, which Fluid Speech Pro is built on: FluidAudio decodes it as v3.
        let models = try AsrModels.loadLocal(from: directory, version: .ultra)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    /// Boosts these words from the next dictation on. A word replaces what the model wrote only where the CTC model hears it.
    /// Dictation keeps working unboosted while the CTC model downloads, or if it fails to.
    public func setVocabulary(_ entries: [DictionaryEntry]) async throws {
        vocabularyVersion += 1
        let version = vocabularyVersion
        guard !entries.isEmpty else { return boosting = nil }
        // One download however many lists arrive while it runs; a failed one is tried again with the next list.
        let load = ctcLoad ?? Task { try await CtcModels.downloadAndLoad() }
        ctcLoad = load
        let ctcModels: CtcModels
        do { ctcModels = try await load.value } catch {
            ctcLoad = nil
            throw error
        }
        let terms = entries.map { CustomVocabularyTerm(text: $0.word, aliases: $0.heardAs.isEmpty ? nil : $0.heardAs) }
        let session = try await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(terms: terms), ctcModels: ctcModels)
        if version == vocabularyVersion { boosting = session }  // a newer list arrived while this one was building
    }

    // shortcut: context.precedingText is ignored.
    public func transcribe(_ samples: [Float], context: RecognitionContext) async throws -> String {
        guard let manager else { throw SessionError.modelUnavailable }
        // Very short clips are padded with silence; FluidAudio rejects them otherwise.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        let audio = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        guard let boosting else { return result.text }
        let rescored = await boosting.rescore(text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: audio)
        return rescored?.text ?? result.text
    }
}

extension SpeechRecognizer {
    /// Where the model is stored on disk.
    public static var modelDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Glide/Models/fluid-speech-pro-coreml", isDirectory: true)
    }

    public static let modelName = "Fluid Speech Pro"
    public static let attribution = FluidSpeechPro.attribution
}
