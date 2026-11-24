import AudioCapture
import GlideCore
import SwiftUI

@main
struct GlideApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu().environment(app)
        } label: {
            MenuBarLabel(app: app)
        }

        Window("Glide", id: "main") {
            MainWindow().environment(app)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 860, height: 600)

        Window("Welcome to Glide", id: "setup") {
            SetupWindow().environment(app)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Settings", id: "settings") {
            SettingsView().environment(app)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// The menu bar glyph. SwiftUI renders it at launch, so it also hands the model a way to open windows.
private struct MenuBarLabel: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: Self.glyph)
            .onAppear {
                app.openWindow = { openWindow(id: $0) }
                // `open Glide.app --args -showMain YES` starts with the main window up.
                if !app.isSetupDone { app.open("setup") } else if UserDefaults.standard.bool(forKey: "showMain") { app.open("main") }
            }
    }

    @MainActor private static let glyph: NSImage = {
        let renderer = ImageRenderer(content: CaretMark().foregroundStyle(.black).frame(width: 16, height: 16))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        image.accessibilityDescription = "Glide"
        return image
    }()
}

private struct MenuBarMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Text(app.status)
        Divider()
        Picker("Microphone", selection: $app.microphoneID) {
            Text("System Default").tag("")
            ForEach(app.microphones) { Text($0.name).tag($0.id) }
        }
        Toggle("Pause Glide", isOn: $app.paused)
        Divider()
        if !app.isSetupDone { Button("Set Up Glide…") { app.open("setup") } }
        Button("Open Glide") { app.open("main") }
        Button("Settings…") { app.open("settings") }.keyboardShortcut(",")
        Divider()
        Button("Quit Glide") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
