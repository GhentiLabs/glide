import Foundation
import GlideCore
import Testing
@testable import EditTracker

/// A field that answers each read with the next scripted value and repeats the last one.
private final class ScriptedField: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [EditTracker.Read]
    private var returnsSoFar = 0
    /// Press Return just before this read index.
    private let returnAt: Int?
    private var reads = 0

    init(_ script: [EditTracker.Read], returnAt: Int? = nil) {
        self.script = script
        self.returnAt = returnAt
    }

    func read() -> EditTracker.Read {
        lock.withLock {
            reads += 1
            if reads == returnAt { returnsSoFar += 1 }
            return script.count > 1 ? script.removeFirst() : script[0]
        }
    }

    var returns: Int { lock.withLock { returnsSoFar } }
    var readCount: Int { lock.withLock { reads } }
}

@Suite struct EditTrackerTests {
    private var fast: EditTracker.Timing {
        var t = EditTracker.Timing()
        t.settle = .milliseconds(1)
        t.interval = .milliseconds(1)
        t.returnCheck = .milliseconds(20)
        t.limit = .seconds(5)
        return t
    }

    private func track(_ pasted: String, _ field: ScriptedField, timing: EditTracker.Timing? = nil) async -> EditTracker.Result {
        await EditTracker.track(pasted: pasted, timing: timing ?? fast, returns: { field.returns }, read: { field.read() })
    }

    private func text(_ s: String, cursor: Int? = nil) -> EditTracker.Read { .text(s, cursor: cursor) }

    @Test func returnThatClearsTheFieldKeepsTheLastEdit() async {
        let field = ScriptedField([
            text("Hi team, deploy it to cooper netties now"),
            text("Hi team, deploy it to Kubernetes now"),
            text(""),
        ], returnAt: 3)
        let result = await track("deploy it to cooper netties now", field)
        #expect(result == .init(final: "deploy it to Kubernetes now", outcome: .sent))
    }

    @Test func returnInATerminalStopsBeforeTheOutputArrives() async {
        // The prompt stays, so the anchor before the paste still matches; the output after it must not count.
        let field = ScriptedField([
            text("~ % git status"),
            text("~ % git stash"),
            text("~ % git stash\nSaved working directory\n~ %"),
        ], returnAt: 3)
        let result = await track("git status", field)
        #expect(result == .init(final: "git stash", outcome: .sent))
    }

    @Test func returnThatAddsALineKeepsTracking() async {
        let field = ScriptedField([
            text("Notes: buy milk"),
            text("Notes: buy milk\n"),
            text("Notes: buy milk\n"),
            text("Notes: buy oat milk\n"),
            .gone,
        ], returnAt: 2)
        var timing = fast
        timing.returnCheck = .milliseconds(0)
        let result = await track("buy milk", field, timing: timing)
        #expect(result == .init(final: "buy oat milk", outcome: .fieldGone))
    }

    @Test func picksTheCopyNearestTheCursor() async {
        let field = ScriptedField([
            text("ok. ok. ok.", cursor: 7),
            text("ok. okay. ok."),
            .gone,
        ])
        let result = await track("ok.", field)
        #expect(result.final == "okay.")
    }

    @Test func terminalRewrapIsNotAnEdit() async {
        let field = ScriptedField([text("$ echo one two three"), text("$ echo one\n  two three"), .gone])
        #expect(await track("echo one two three", field).final == "echo one two three")
    }

    @Test func pausedReadsAreSkippedAndFailuresStopIt() async {
        let field = ScriptedField([text("say hi"), .paused, .paused, text("say hello"), .failed, .failed, .failed])
        #expect(await track("say hi", field) == .init(final: "say hello", outcome: .readFailures))
    }

    @Test func editedAnchorsEndTrackingWithTheLastGoodCut() async {
        let field = ScriptedField([text("Dear Sam, see you soon. Best"), text("Dear Sam, see you Friday. Best"), text("Totally different")])
        #expect(await track("see you soon.", field) == .init(final: "see you Friday.", outcome: .anchorsLost))
    }

    @Test func skipReasons() async {
        #expect(await track("hello", ScriptedField([text("something else")])).skipReason == .pastedTextNotFound)
        #expect(await track("hello", ScriptedField([.failed])).skipReason == .fieldUnreadable)
        #expect(await track("hello", ScriptedField([.gone])).skipReason == .focusLost)
    }

    @Test func timesOut() async {
        var timing = fast
        timing.limit = .milliseconds(30)
        #expect(await track("hi", ScriptedField([text("hi there")]), timing: timing).outcome == .timeout)
    }

    @Test func cancellationIsSuperseded() async {
        let field = ScriptedField([text("draft one"), text("draft two")])
        let task = Task { await track("draft one", field) }
        // Wait for the tracker to have seen "draft two", not a fixed time, which a busy CI runner overruns.
        while field.readCount < 3 { try? await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        #expect(await task.value == .init(final: "draft two", outcome: .superseded))
    }
}
