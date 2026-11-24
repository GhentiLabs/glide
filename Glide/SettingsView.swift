import AppKit
import Recognizer
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            HotkeySettings().tabItem { Label("Hotkeys", systemImage: "keyboard") }
            AudioSettings().tabItem { Label("Audio", systemImage: "mic") }
            ModelSettings().tabItem { Label("Model", systemImage: "cpu") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 520)
        .formStyle(.grouped)
        .onAppear { NSApp.activate() }
    }
}

private struct GeneralSettings: View {
    @AppStorage("soundsEnabled") private var sounds = true
    @AppStorage("smartSpacing") private var smartSpacing = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    openAtLogin = SMAppService.mainApp.status == .enabled
                }
            Toggle("Play sounds", isOn: $sounds)
            Toggle(isOn: $smartSpacing) {
                Text("Fit text to the cursor")
                Text("Adds a space and matches capitals to the text already there.")
            }
        }
    }
}

private struct HotkeySettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Dictate") { Keycap("fn") }
                LabeledContent("Paste last dictation") { Keycap("⌃ ⌘ V") }
                LabeledContent("Cancel") { Keycap("esc") }
            } footer: {
                Text("Hold fn to dictate. Double-tap it to keep recording until you press it again. Other keys can't be chosen yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label).font(.system(.callout, design: .rounded).weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    }
}

private struct AudioSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage("duckAudio") private var duck = true

    var body: some View {
        @Bindable var app = app
        Form {
            Picker("Microphone", selection: $app.microphoneID) {
                Text("System Default").tag("")
                ForEach(app.microphones) { Text($0.name).tag($0.id) }
            }
            Toggle(isOn: $duck) {
                Text("Lower other audio while dictating")
                Text("Music and calls get quieter while you hold the hotkey.")
            }
        }
        .onAppear { app.refreshMicrophones() }
    }
}

private struct ModelSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            LabeledContent("Speech model", value: "Parakeet TDT 0.6B v3")
            LabeledContent("Status") {
                if app.modelFailed {
                    Text("Failed to load")
                } else if let progress = app.modelProgress {
                    ProgressView(value: progress).frame(width: 160)
                } else {
                    Text("Ready")
                }
            }
            LabeledContent("Runs on", value: "This Mac")
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ParakeetRecognizer.modelDirectory]) }
        }
    }
}

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var app
    @State private var confirming = false

    var body: some View {
        Form {
            Section {
                Text("Your audio, history and dictionary stay on this Mac. Glide goes online only to download the speech model.")
            }
            LabeledContent("History", value: "\(app.store.records.count) dictations")
            Button("Clear History…", role: .destructive) { confirming = true }
                .disabled(app.store.records.isEmpty)
                .confirmationDialog("Clear all of your dictation history?", isPresented: $confirming) {
                    Button("Clear History", role: .destructive) { app.store.clearHistory() }
                } message: {
                    Text("This can't be undone. Your dictionary is kept.")
                }
        }
    }
}
