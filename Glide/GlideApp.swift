import GlideCore
import SwiftUI

@main
struct GlideApp: App {
    @State private var dictation = DictationController()

    var body: some Scene {
        // shortcut: menu bar only until the main window, first run and Settings land in M4.
        MenuBarExtra {
            Text(dictation.status)
            Divider()
            Button("Quit Glide") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(nsImage: Self.menuBarGlyph)
        }
    }

    @MainActor private static let menuBarGlyph: NSImage = {
        let renderer = ImageRenderer(content: CaretMark().foregroundStyle(.black).frame(width: 16, height: 16))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }()
}
