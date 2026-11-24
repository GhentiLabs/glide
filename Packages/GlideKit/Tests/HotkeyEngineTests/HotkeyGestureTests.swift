import Testing
@testable import HotkeyEngine

@Suite struct HotkeyGestureTests {
    @Test func holdStartsAndReleaseSubmits() {
        var g = HotkeyGesture()
        #expect(g.keyDown(at: 0) == .start)
        #expect(g.keyDown(at: 0.1) == nil)  // autorepeat
        #expect(g.keyUp(at: 1.2) == .submit)
        #expect(!g.isRecording)
    }

    @Test func singleTapIsThrownAway() {
        var g = HotkeyGesture()
        #expect(g.keyDown(at: 0) == .start)
        #expect(g.keyUp(at: 0.1) == .cancel)
    }

    @Test func doubleTapLatchesThenNextPressSubmits() {
        var g = HotkeyGesture()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.1)
        #expect(g.keyDown(at: 0.3) == .start)
        #expect(g.keyUp(at: 0.4) == .latchHandsFree)
        #expect(g.isRecording)
        #expect(g.keyDown(at: 3) == .submit)
        #expect(g.keyUp(at: 3.1) == nil)
        #expect(g.keyDown(at: 5) == .start)  // back to normal
    }

    @Test func slowSecondTapDoesNotLatch() {
        var g = HotkeyGesture()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.1)
        _ = g.keyDown(at: 0.9)
        #expect(g.keyUp(at: 1.0) == .cancel)
    }

    @Test func pressSoonAfterLatchingCancels() {
        var g = HotkeyGesture()
        _ = g.keyDown(at: 0)
        _ = g.keyUp(at: 0.1)
        _ = g.keyDown(at: 0.2)
        _ = g.keyUp(at: 0.3)
        #expect(g.keyDown(at: 0.6) == .cancel)
    }

    @Test func escapeCancelsOnlyWhileRecording() {
        var g = HotkeyGesture()
        #expect(g.escape() == nil)
        _ = g.keyDown(at: 0)
        #expect(g.escape() == .cancel)
        #expect(g.keyUp(at: 2) == nil)
    }
}
