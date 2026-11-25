import AppKit
import ApplicationServices
import GlideCore

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

/// A text field held after a paste, so the edit tracker keeps reading the same one even if focus moves within the app.
public final class TrackedField: @unchecked Sendable {
    let element: AXUIElement
    public let pid: pid_t
    public let kind: FieldKind

    init(element: AXUIElement, pid: pid_t, kind: FieldKind) {
        self.element = element
        self.pid = pid
        self.kind = kind
    }
}

public enum FieldRead: Sendable {
    /// The text, and the cursor as a character offset into it when known.
    case text(String, cursor: Int?)
    case failed
    /// The element died: its window closed or the app quit.
    case gone
}

/// Reads and writes the focused text field through Accessibility.
/// shortcut: the snapshot before recording reads native fields only; web fields get their text from markers after the paste, without a cursor.
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

    /// The focused field, held for tracking. Nil for password fields and when nothing has focus.
    public static func trackedField() -> TrackedField? {
        guard let element = focusedElement(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let role: String? = attribute(element, kAXRoleAttribute)
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        guard role != "AXSecureTextField", subrole != "AXSecureTextField" else { return nil }
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let web = (attribute(element, kAXValueAttribute) as String?) == nil
        return TrackedField(element: element, pid: pid, kind: terminals.contains(bundle) ? .terminal : web ? .web : .native)
    }

    /// One read of a held field. Blocks for up to `timeout`; call off the main thread.
    /// Very long fields (terminal scrollback, big documents) are read as a window around the cursor.
    public static func read(_ field: TrackedField) -> FieldRead {
        let element = field.element
        var count: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count)
        if status == .invalidUIElement { return .gone }
        if let count = count as? Int, count > windowThreshold {
            let caret = selection(element)?.location ?? count
            let start = max(0, caret - window / 2), length = min(count, caret + window / 2) - start
            var range = CFRange(location: start, length: length)
            guard let value = AXValueCreate(.cfRange, &range), let text: String = parameterized(element, kAXStringForRangeParameterizedAttribute, value)
            else { return .failed }
            return .text(text, cursor: characters(in: text, utf16: caret - start))
        }
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) {
        case .success:
            if let text = value as? String { return .text(text, cursor: selection(element).flatMap { characters(in: text, utf16: $0.location) }) }
        case .invalidUIElement: return .gone
        default: break
        }
        // Web content that exposes no string value: read it through text markers.
        guard let range: AnyObject = parameterized(element, "AXTextMarkerRangeForUIElement", element),
            let text: String = parameterized(element, "AXStringForTextMarkerRange", range)
        else { return .failed }
        return .text(text, cursor: nil)
    }

    static let windowThreshold = 50_000
    static let window = 8_000
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "org.alacritty", "com.github.wez.wezterm",
    ]

    private static func selection(_ element: AXUIElement) -> CFRange? {
        guard let value: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    /// Accessibility counts UTF-16 units; the tracker counts characters.
    private static func characters(in text: String, utf16 offset: Int) -> Int? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        return String(text.utf16.prefix(offset))?.count
    }

    private static func parameterized<T>(_ element: AXUIElement, _ name: String, _ parameter: AnyObject) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success else { return nil }
        return value as? T
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
