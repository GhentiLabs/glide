import FluidAudio
import GlideCore

/// Parakeet TDT 0.6B v3 on Core ML, through FluidAudio.
public actor ParakeetRecognizer: GlideCore.Recognizer {
    private var manager: AsrManager?

    public init() {}

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3) { progress($0.fractionCompleted) }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    // shortcut: context is ignored; decode-time biasing from the dictionary arrives in M5.
    public func transcribe(_ samples: [Float], context: RecognitionContext) async throws -> String {
        guard let manager else { throw SessionError.modelUnavailable }
        // Very short clips are padded with silence; FluidAudio rejects them otherwise.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        let audio = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(audio, decoderState: &state).text
    }
}
