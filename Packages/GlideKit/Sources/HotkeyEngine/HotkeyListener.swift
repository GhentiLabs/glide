import CoreGraphics
import Foundation

/// Listens for fn/Globe, Escape and Control-Command-V through an active HID-level event tap on its own thread.
/// shortcut: fn is the only binding; the session-level tap for other keys and mouse buttons arrives with the Hotkeys settings (M4).
public final class HotkeyListener: @unchecked Sendable {
    public enum ListenerError: Error { case notTrusted }

    private static let fnKeyCode: Int64 = 63
    private static let escapeKeyCode: Int64 = 53

    private static let vKeyCode: Int64 = 9
    private static let returnKeyCodes: Set<Int64> = [36, 76]  // Return and keypad Enter

    private let onAction: @Sendable (HotkeyGesture.Action) -> Void
    private let onPasteLast: @Sendable () -> Void
    private let lock = NSLock()
    // Guarded by `lock`: the tap thread and the main thread both touch them.
    private var gesture = HotkeyGesture()
    private var fnDown = false
    private var paused = false
    private var tap: CFMachPort?
    private var returns = 0

    /// Return presses seen so far, from any app. The edit tracker watches it to tell a sent message from a new line.
    public var returnCount: Int { lock.withLock { returns } }

    /// Both callbacks run on the main queue.
    public init(onAction: @escaping @Sendable (HotkeyGesture.Action) -> Void, onPasteLast: @escaping @Sendable () -> Void) {
        self.onAction = onAction
        self.onPasteLast = onPasteLast
    }

    /// While paused every key passes through untouched.
    public func setPaused(_ value: Bool) {
        lock.withLock {
            paused = value
            gesture = HotkeyGesture()
        }
    }

    /// Forget the current gesture, after a recording ended some other way (the bar's stop button).
    public func reset() { lock.withLock { gesture = HotkeyGesture() } }

    /// Needs Accessibility trust; throws `notTrusted` without it.
    public func start() throws {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                callback: { _, type, event, info in
                    let listener = Unmanaged<HotkeyListener>.fromOpaque(info!).takeUnretainedValue()
                    return listener.handle(type: type, event: event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { throw ListenerError.notTrusted }
        self.tap = tap
        let thread = Thread { [self] in
            guard let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Glide hotkey tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Not event.timestamp: on Apple silicon it counts mach ticks, not nanoseconds, which made every hold look like a tap.
        let t = ProcessInfo.processInfo.systemUptime
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        var action: HotkeyGesture.Action?
        var pasteLast = false
        let swallow: Bool = lock.withLock {
            if type == .keyDown, Self.returnKeyCodes.contains(keyCode) { returns += 1 }
            guard !paused else { return false }
            switch type {
            case .flagsChanged where keyCode == Self.fnKeyCode:
                let down = event.flags.contains(.maskSecondaryFn)
                guard down != fnDown else { return false }
                fnDown = down
                action = down ? gesture.keyDown(at: t) : gesture.keyUp(at: t)
                return true  // keeps macOS from opening the emoji picker or its own dictation
            case .keyDown where keyCode == Self.escapeKeyCode:
                action = gesture.escape()
                return action != nil
            case .keyDown where keyCode == Self.vKeyCode
                && event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == [.maskCommand, .maskControl]:
                // shortcut: physical V key; a layout-aware binding arrives with rebindable hotkeys.
                pasteLast = event.getIntegerValueField(.keyboardEventAutorepeat) == 0
                return true
            default:
                return false
            }
        }
        if let action {
            let onAction = onAction
            DispatchQueue.main.async { onAction(action) }
        }
        if pasteLast { DispatchQueue.main.async(execute: onPasteLast) }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
