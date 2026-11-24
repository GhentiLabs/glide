import Foundation

/// Audio plus context in, text out.
public protocol Recognizer: Sendable {
    /// Loads (and if needed downloads) the model. `progress` gets 0...1.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    /// `samples` are 16 kHz mono Float32.
    func transcribe(_ samples: [Float], context: RecognitionContext) async throws -> String
}

public struct RecognitionContext: Sendable {
    /// Words to favour during decoding (dictionary entries).
    public var biasWords: [String]
    /// Text just before the cursor, if the field could be read.
    public var precedingText: String?

    public init(biasWords: [String] = [], precedingText: String? = nil) {
        self.biasWords = biasWords
        self.precedingText = precedingText
    }
}
