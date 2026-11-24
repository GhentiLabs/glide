import CoreGraphics
import Foundation

/// Listens for fn/Globe and Escape through an active HID-level event tap on its own thread.
/// shortcut: fn is the only binding; the session-level tap for other keys and mouse buttons arrives with the Hotkeys settings (M4).
public final class HotkeyListener: @unchecked Sendable {
    public enum ListenerError: Error { case notTrusted }

    private static let fnKeyCode: Int64 = 63
    private static let escapeKeyCode: Int64 = 53

    private let onAction: @Sendable (HotkeyGesture.Action) -> Void
    // Touched only on the tap thread.
    private var gesture = HotkeyGesture()
    private var fnDown = false
    private var tap: CFMachPort?

    /// `onAction` is called on the main queue.
    public init(onAction: @escaping @Sendable (HotkeyGesture.Action) -> Void) {
        self.onAction = onAction
    }

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
        // Not event.timestamp: on Apple silicon it counts mach ticks, not nanoseconds, which made every hold look like a tap.
        let t = ProcessInfo.processInfo.systemUptime
        var action: HotkeyGesture.Action?
        var swallow = false
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .flagsChanged where event.getIntegerValueField(.keyboardEventKeycode) == Self.fnKeyCode:
            let down = event.flags.contains(.maskSecondaryFn)
            guard down != fnDown else { return Unmanaged.passUnretained(event) }
            fnDown = down
            action = down ? gesture.keyDown(at: t) : gesture.keyUp(at: t)
            swallow = true  // keeps macOS from opening the emoji picker or its own dictation
        case .keyDown where event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode:
            action = gesture.escape()
            swallow = action != nil
        default:
            break
        }
        if let action {
            let onAction = onAction
            DispatchQueue.main.async { onAction(action) }
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
