import AppKit
import Recognizer
import ServiceManagement
import GlideCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            HotkeySettings().tabItem { Label("Hotkeys", systemImage: "keyboard") }
            AudioSettings().tabItem { Label("Audio", systemImage: "mic") }
            LearningSettings().tabItem { Label("Learning", systemImage: "sparkles") }
            ModelSettings().tabItem { Label("Model", systemImage: "cpu") }
            GhentiSettings().tabItem { Label("Ghenti", systemImage: "person.crop.circle") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 720)  // seven tabs fit without the toolbar overflowing
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

private struct LearningSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage("learnFromEdits") private var learn = true
    @AppStorage("keepRecordings") private var keepRecordings = true
    @State private var confirming = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $learn) {
                    Text("Learn from my edits")
                    Text("After Glide types, it reads the field until you move on, to see what you fix.")
                }
                Toggle(isOn: $keepRecordings) {
                    Text("Keep recordings")
                    Text("Encrypted on this Mac. Recordings you didn't correct are deleted after 30 days.")
                }
            } footer: {
                Text("Only the text Glide typed is kept. Password fields are never read.").foregroundStyle(.secondary)
            }
            LabeledContent("Words learned", value: "\(app.store.dictionary.count)")
            Button("Delete Learning Data…", role: .destructive) { confirming = true }
                .confirmationDialog("Delete what Glide has learned?", isPresented: $confirming) {
                    Button("Delete Learning Data", role: .destructive) {
                        app.store.clearLearningData()
                        app.audio.removeAll()
                    }
                } message: {
                    Text("Every word, correction label and recording goes. Your history text stays.")
                }
        }
    }
}

private struct ModelSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                LabeledContent("Speech model", value: SpeechRecognizer.modelName)
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
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([SpeechRecognizer.modelDirectory]) }
            } footer: {
                Text(SpeechRecognizer.attribution + " CC BY 4.0.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct GhentiSettings: View {
    @Environment(AppModel.self) private var app
    @State private var confirmingSyncOff = false
    @State private var confirmingShareOff = false
    @State private var crashReports = Telemetry.crashReports
    @State private var usageStatistics = Telemetry.usageStatistics

    private var account: Account { app.account }

    var body: some View {
        Form {
            Section {
                if let user = account.user {
                    LabeledContent(user.name ?? "Ghenti account") { Text(user.email ?? "").foregroundStyle(.secondary) }
                    Button("Sign Out") { Task { await account.signOut() } }
                } else {
                    LabeledContent("Ghenti account") {
                        Button("Sign In…") { app.open("ghenti") }
                    }
                }
            } footer: {
                if let problem = account.problem { Text(problem).foregroundStyle(.red) }
            }

            Section {
                Toggle(isOn: Binding(get: { account.syncEnabled }, set: { on in
                    if on { Task { await account.setSync(true) } } else { confirmingSyncOff = true }
                })) {
                    Text("Sync across my devices")
                    Text("Text, edits and recordings, encrypted with your Ghenti vault key. With your vault set to Only me, nobody but you can read them.")
                }
                .disabled(account.user == nil || account.activity != nil)
                if account.syncEnabled {
                    if !account.hasKey {
                        LabeledContent("Vault locked") { Button("Unlock…") { Task { await account.unlock() } } }
                    } else {
                        LabeledContent("Last synced") {
                            Text(account.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet")
                            Button("Sync Now") { Task { await account.syncNow() } }
                        }
                    }
                }
            }
            .confirmationDialog("Turn off sync?", isPresented: $confirmingSyncOff) {
                Button("Turn Off and Delete from Ghenti", role: .destructive) { Task { await account.setSync(false, deleteFromGhenti: true) } }
                Button("Turn Off") { Task { await account.setSync(false) } }
            } message: {
                Text("Your dictations stay on this Mac either way. Deleting also removes them from your other devices' sync.")
            }

            Section {
                Toggle(isOn: Binding(get: { account.sharesForTraining }, set: { on in
                    if on { Task { await account.setSharing(true) } } else { confirmingShareOff = true }
                })) {
                    Text("Share my dictations to improve Glide")
                    Text("A copy of each dictation, its edits and its recording, encrypted so only Ghenti's training system can read it. Names and contact details are removed from the text and your account is left out, but the recording keeps your voice. Ghenti uses these copies to train Glide's models.")
                }
                .disabled(account.user == nil || account.activity != nil)
                Link("What's shared and how it's protected", destination: URL(string: "https://ghenti.com/apps/glide/privacy")!)
            }
            .confirmationDialog("Stop sharing?", isPresented: $confirmingShareOff) {
                Button("Stop Sharing and Delete", role: .destructive) { Task { await account.setSharing(false) } }
            } message: {
                Text("Everything you shared is deleted from Ghenti.")
            }

            Section {
                Toggle(isOn: $crashReports) {
                    Text("Send crash reports")
                    Text("What Glide was doing when it crashed or hung.")
                }
                .onChange(of: crashReports) { _, on in Telemetry.crashReports = on }
                Toggle(isOn: $usageStatistics) {
                    Text("Send usage statistics")
                    Text("Which features get used, with no account or device ID.")
                }
                .onChange(of: usageStatistics) { _, on in Telemetry.usageStatistics = on }
            } footer: {
                Text("Neither includes what you dictate. Both go to Ghenti's own servers and work without signing in.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var app
    @State private var confirming = false

    var body: some View {
        Form {
            Section {
                Text("Your audio, history and learned words stay on this Mac unless you turn on sync or sharing in Ghenti settings. Otherwise Glide goes online only to download its speech models.")
            }
            LabeledContent("History", value: "\(app.store.records.count) dictations")
            Button("Clear History…", role: .destructive) { confirming = true }
                .disabled(app.store.records.isEmpty)
                .confirmationDialog("Clear all of your dictation history?", isPresented: $confirming) {
                    Button("Clear History", role: .destructive) { app.store.clearHistory() }
                } message: {
                    Text("This can't be undone. Learned words are kept.")
                }
        }
    }
}
