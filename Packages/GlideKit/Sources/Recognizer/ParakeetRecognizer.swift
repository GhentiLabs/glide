import Foundation
import FluidAudio
import GlideCore

/// Parakeet TDT 0.6B v3 on Core ML, through FluidAudio.
public actor ParakeetRecognizer: GlideCore.Recognizer {
    private var manager: AsrManager?
    /// A separate 110M CTC model that checks vocabulary words against the audio. Downloaded once the vocabulary has a word.
    private var ctcLoad: Task<CtcModels, Error>?
    private var boosting: VocabularyBoostingSession?
    private var vocabularyVersion = 0

    public init() {}

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3) { progress($0.fractionCompleted) }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    /// Boosts these words from the next dictation on. A word replaces what Parakeet wrote only where the CTC model hears it.
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

extension ParakeetRecognizer {
    /// Where the model is stored on disk.
    public static var modelDirectory: URL { AsrModels.defaultCacheDirectory(for: .v3) }
}
