import AppKit
import Carbon.HIToolbox

/// Inserts text at the cursor by pasting, then puts the user's clipboard back.
@MainActor
public enum Inserter {
    /// Marks our pasteboard write so clipboard managers skip it (nspasteboard.org).
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// How long the front app gets to read the paste before the clipboard is restored anyway.
    static let readTimeout = Duration.seconds(1)

    /// Pastes `text` and returns once the front app has read it (true) or `readTimeout` passed (false).
    /// The user's clipboard is restored after either.
    @discardableResult
    public static func paste(_ text: String) async -> Bool {
        await paste(text, on: .general, send: postCommandV)
    }

    /// The text is served lazily, so the read itself tells us the paste was consumed.
    /// shortcut: a clipboard manager that ignores the transient type and reads first counts as the read; key off field changes if that shows up.
    static func paste(_ text: String, on board: NSPasteboard, send: () -> Void) async -> Bool {
        let saved = snapshot(board)
        let provider = LazyText(text)
        board.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        item.setData(Data(), forType: transient)
        item.setData(Data(), forType: concealed)
        board.writeObjects([item])
        let ours = board.changeCount
        send()
        let deadline = ContinuousClock.now + readTimeout
        while !provider.read, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Something else wrote to the clipboard meanwhile; theirs wins.
        if board.changeCount == ours {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
        return provider.read
    }

    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }

    private static func postCommandV() {
        let key = keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    /// The key that types `character` with Command held in the current layout, so Dvorak and AZERTY users get a paste.
    private static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> CGKeyCode? in
            let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            for code in 0..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDisplay), UInt32((cmdKey >> 8) & 0xFF),
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                if status == noErr, length == 1, Character(UnicodeScalar(chars[0])!) == character {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}

/// Hands over the text when an app asks for it, and remembers that it asked.
private final class LazyText: NSObject, NSPasteboardItemDataProvider {
    let text: String
    nonisolated(unsafe) var read = false

    init(_ text: String) { self.text = text }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        read = true
        item.setString(text, forType: type)
    }
}
