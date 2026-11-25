import Foundation
import GlideCore

/// Watches a text field after a paste and returns the user's version of the pasted text.
///
/// It finds the paste in the field, keeps a little text on each side as anchors, and re-reads the field until the
/// user moves on. Anchors and field text stay in memory; only the cut-out span is returned.
public enum EditTracker {
    /// One read of the field.
    public enum Read: Sendable {
        /// The field's text, and the cursor as a character offset into it when known.
        case text(String, cursor: Int?)
        /// The read failed this time.
        case failed
        /// The field is gone: its window closed or the element died.
        case gone
        /// Another app is in front; this read doesn't count.
        case paused
    }

    public enum Outcome: String, Sendable {
        /// Return sent the text, or the field emptied.
        case sent
        /// A new dictation started.
        case superseded
        case fieldGone, readFailures, timeout
        /// The text around the dictation changed, so the span can no longer be cut out.
        case anchorsLost
    }

    public struct Result: Sendable, Equatable {
        /// The user's version of the pasted text; nil when tracking never started.
        public var final: String?
        public var skipReason: SkipReason?
        public var outcome: Outcome?
    }

    public struct Timing: Sendable {
        public var settle: Duration = .milliseconds(150)
        public var interval: Duration = .milliseconds(100)
        /// How long after Return before deciding whether it sent the text.
        public var returnCheck: Duration = .milliseconds(500)
        public var limit: Duration = .seconds(300)
        public static let standard = Timing()
        public init() {}
    }

    /// Characters kept on each side of the paste to find it again.
    static let anchorLength = 32
    static let failureLimit = 3

    /// Runs until the user moves on or the task is cancelled (a new dictation), which counts as superseded.
    /// `returns` counts Return presses so far; the tracker notices when it grows.
    public static func track(
        pasted: String, timing: Timing = .standard, returns: @escaping @Sendable () -> Int,
        read: @escaping @Sendable () async -> Read
    ) async -> Result {
        let clock = ContinuousClock()
        let started = clock.now
        let needle = collapsed(pasted).trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return Result(final: nil, skipReason: .pastedTextNotFound) }
        try? await Task.sleep(for: timing.settle)
        if Task.isCancelled { return Result(final: nil, skipReason: .replacedByNewDictation) }

        // Find the paste: the match ending nearest the cursor.
        var first = await read()
        while case .paused = first {
            try? await Task.sleep(for: timing.interval)
            if Task.isCancelled { return Result(final: nil, skipReason: .replacedByNewDictation) }
            first = await read()
        }
        let text: String, cursor: Int?
        switch first {
        case .text(let t, let c): (text, cursor) = (t, c)
        case .gone: return Result(final: nil, skipReason: .focusLost)
        case .failed, .paused: return Result(final: nil, skipReason: .fieldUnreadable)
        }
        let field = collapsed(text)
        let caret = cursor.map { collapsed(String(text.prefix($0))).count } ?? field.count
        guard let match = ranges(of: needle, in: field).min(by: { abs(offset($0.upperBound, field) - caret) < abs(offset($1.upperBound, field) - caret) })
        else { return Result(final: nil, skipReason: .pastedTextNotFound) }
        let prefix = String(field[..<match.lowerBound].suffix(anchorLength))
        let suffix = String(field[match.upperBound...].prefix(anchorLength))
        var start = offset(match.lowerBound, field)
        var last = needle
        var failures = 0
        var seenReturns = returns()
        var held: (text: String, at: ContinuousClock.Instant)?

        func done(_ outcome: Outcome, _ final: String? = nil) -> Result { Result(final: final ?? held?.text ?? last, outcome: outcome) }

        while true {
            try? await Task.sleep(for: timing.interval)
            if Task.isCancelled { return done(.superseded) }
            if clock.now - started > timing.limit { return done(.timeout) }
            let now = await read()
            let value: String
            switch now {
            case .paused: continue
            case .gone: return done(.fieldGone)
            case .failed:
                failures += 1
                if failures >= failureLimit { return done(.readFailures) }
                continue
            case .text(let t, _): value = collapsed(t)
            }
            failures = 0
            let count = returns()
            if count > seenReturns, held == nil { held = (last, clock.now) }
            seenReturns = count
            if value.trimmingCharacters(in: .whitespaces).isEmpty { return done(.sent) }
            guard let cut = cut(value, prefix: prefix, suffix: suffix, near: start) else {
                return done(held != nil ? .sent : .anchorsLost)
            }
            if let h = held {
                guard clock.now - h.at >= timing.returnCheck else { continue }
                // Return added a line: same words, keep going. Anything else means the text went and the field moved on.
                guard words(cut.text) == words(h.text) else { return done(.sent) }
                held = nil
            }
            last = cut.text
            start = cut.start
        }
    }

    /// The text between the anchors, found nearest where the paste was last seen.
    static func cut(_ field: String, prefix: String, suffix: String, near: Int) -> (text: String, start: Int)? {
        let starts: [String.Index] = prefix.isEmpty ? [field.startIndex] : ranges(of: prefix, in: field).map(\.upperBound)
        guard let from = starts.min(by: { abs(offset($0, field) - near) < abs(offset($1, field) - near) }) else { return nil }
        let to: String.Index
        if suffix.isEmpty {
            to = field.endIndex
        } else {
            guard let r = field.range(of: suffix, options: .literal, range: from..<field.endIndex) else { return nil }
            to = r.lowerBound
        }
        return (String(field[from..<to]).trimmingCharacters(in: .whitespaces), offset(from, field))
    }

    /// Runs of whitespace as one space, so a terminal re-wrapping a line doesn't look like an edit.
    static func collapsed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private static func words(_ text: String) -> [Substring] { text.split(whereSeparator: \.isWhitespace) }

    private static func offset(_ index: String.Index, _ text: String) -> Int { text.distance(from: text.startIndex, to: index) }

    private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while let r = text.range(of: needle, options: .literal, range: from..<text.endIndex) {
            found.append(r)
            from = text.index(after: r.lowerBound)
        }
        return found
    }
}
