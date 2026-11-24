import Foundation

/// What one dictation session is doing. The bar draws one look per case.
public enum SessionState: Equatable, Sendable {
    case idle
    /// Hotkey is down but the microphone or model is not ready yet.
    case initializing
    case recording(handsFree: Bool)
    case transcribing
    case completed
    case error(SessionError)
}

public enum SessionError: Error, Equatable, Sendable {
    case microphoneDenied
    case accessibilityDenied
    case modelUnavailable
    case nothingHeard
    case recognitionFailed(String)
    case insertionFailed
}
