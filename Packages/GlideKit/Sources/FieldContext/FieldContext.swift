import AppKit
import ApplicationServices

/// What was in the focused text field when recording started.
public struct FieldSnapshot: Sendable {
    public var bundleID: String?
    public var role: String?
    public var isSecure: Bool
    /// Nil when the field's text could not be read.
    public var before: String?
    public var selected: String?
    public var after: String?

    public var value: String? { before.map { $0 + (selected ?? "") + (after ?? "") } }
}

/// Reads and writes the focused text field through Accessibility.
/// shortcut: native AXValue and AXSelectedTextRange only; web text markers (contenteditable) come with the edit tracker in M5.
public enum FieldContext {
    /// Stops a hung app from freezing dictation.
    private static let timeout: Float = 0.5
    nonisolated(unsafe) private static var enabledPIDs = Set<pid_t>()
    private static let lock = NSLock()

    /// Nil when nothing has keyboard focus. Blocks for up to `timeout`; call off the main thread.
    public static func snapshot() -> FieldSnapshot? {
        guard let element = focusedElement() else { return nil }
        let role: String? = attribute(element, kAXRoleAttribute)
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        var snapshot = FieldSnapshot(
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, role: role,
            isSecure: role == "AXSecureTextField" || subrole == "AXSecureTextField")
        // Never read a password field.
        guard !snapshot.isSecure, let value: String = attribute(element, kAXValueAttribute),
            let rangeValue: AXValue = attribute(element, kAXSelectedTextRangeAttribute)
        else { return snapshot }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return snapshot }
        // Accessibility counts UTF-16 units.
        let utf16 = value.utf16
        guard range.location >= 0, range.length >= 0, range.location + range.length <= utf16.count else { return snapshot }
        let start = utf16.index(utf16.startIndex, offsetBy: range.location)
        let end = utf16.index(start, offsetBy: range.length)
        snapshot.before = String(value[..<start])
        snapshot.selected = String(value[start..<end])
        snapshot.after = String(value[end...])
        return snapshot
    }

    /// The focused field's whole text, if readable.
    public static func currentValue() -> String? {
        focusedElement().flatMap { attribute($0, kAXValueAttribute) }
    }

    /// Writes `text` over the selection in the focused field. The fallback when a paste does not land.
    public static func insert(_ text: String) -> Bool {
        guard let element = focusedElement() else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { exposeAccessibility(pid) }
        if let element: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(element, timeout)
            return element
        }
        // Some apps answer only through their own application element.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let element: AXUIElement? = attribute(app, kAXFocusedUIElementAttribute)
        if let element { AXUIElementSetMessagingTimeout(element, timeout) }
        return element
    }

    /// Chromium and Electron apps build their accessibility tree only when asked.
    private static func exposeAccessibility(_ pid: pid_t) {
        let isNew = lock.withLock { enabledPIDs.insert(pid).inserted }
        guard isNew else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
