import Foundation

/// Turns hotkey edges into dictation actions, following the spec's timing rules.
public struct HotkeyGesture: Sendable {
    public enum Action: Equatable, Sendable {
        case start
        /// Second quick tap: keep recording after release.
        case latchHandsFree
        case submit
        case cancel
    }

    public static let tapLimit: TimeInterval = 0.25
    public static let doubleTapWindow: TimeInterval = 0.6
    public static let accidentalCancelWindow: TimeInterval = 0.5

    private enum Phase: Sendable {
        case idle
        case holding(since: TimeInterval)
        case handsFree(since: TimeInterval)
        /// The press that ended hands-free; its release does nothing.
        case awaitingRelease
    }

    private var phase = Phase.idle
    private var lastTapEnd: TimeInterval?

    public init() {}

    public var isRecording: Bool {
        switch phase {
        case .holding, .handsFree: true
        case .idle, .awaitingRelease: false
        }
    }

    public mutating func keyDown(at t: TimeInterval) -> Action? {
        switch phase {
        case .idle:
            phase = .holding(since: t)
            return .start
        case .handsFree(let since):
            phase = .awaitingRelease
            return t - since < Self.accidentalCancelWindow ? .cancel : .submit
        case .holding, .awaitingRelease:
            return nil  // autorepeat or a stray edge
        }
    }

    public mutating func keyUp(at t: TimeInterval) -> Action? {
        switch phase {
        case .holding(let since):
            guard t - since < Self.tapLimit else {
                phase = .idle
                return .submit
            }
            if let lastTapEnd, t - lastTapEnd <= Self.doubleTapWindow {
                self.lastTapEnd = nil
                phase = .handsFree(since: t)
                return .latchHandsFree
            }
            lastTapEnd = t
            phase = .idle
            return .cancel  // a tap's brief recording is thrown away
        case .awaitingRelease:
            phase = .idle
            return nil
        case .idle, .handsFree:
            return nil
        }
    }

    /// Returns `.cancel` when Escape should be consumed.
    public mutating func escape() -> Action? {
        guard isRecording else { return nil }
        phase = .idle
        return .cancel
    }
}
