import GlideCore
import Overlay
import SwiftUI

/// First run: one full window, a progress line on top, four steps that each end in a check.
struct SetupWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                StepDots(step: step, count: 4)
                HStack {
                    if step > 0 {
                        Button("Back", systemImage: "chevron.left") { step -= 1 }.buttonStyle(.borderless)
                    }
                    Spacer()
                }
            }
            .frame(height: 28)
            .padding(.horizontal, 20).padding(.top, 14)
            Group {
                switch step {
                case 0: PermissionsStep { step = 1 }
                case 1: MicrophoneStep { step = 2 }
                case 2: HotkeyStep { step = 3 }
                default: TryStep {
                    UserDefaults.standard.set(true, forKey: "setupDone")
                    dismissWindow(id: "setup")
                    app.bar.show(Toast(
                        .tip, symbol: "arrow.down", title: "Glide lives here",
                        message: "Hold fn in any app to dictate. Drag the bar to move it.", keycap: "fn", duration: 9))
                }
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
            .id(step)
            .animation(Tokens.spring, value: step)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 56).padding(.bottom, 40)
        }
        .frame(width: 780, height: 580)
        .background(Tokens.canvas)
        .tint(Tokens.tint)
        .onAppear { NSApp.activate() }
    }
}

/// Four segments; the current one is longer.
private struct StepDots: View {
    let step: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(i <= step ? AnyShapeStyle(Tokens.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: i == step ? 28 : 8, height: 8)
            }
        }
        .animation(Tokens.spring, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1) of \(count)")
    }
}

/// Large title and subtitle shared by every step.
private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(subtitle).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 20).padding(.bottom, 28)
    }
}

/// The card that asks whether the thing just tried worked.
private struct CheckCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 18) { content }
            .frame(maxWidth: 464)
            .card(padding: 28)
    }
}

private struct PermissionsStep: View {
    @Environment(AppModel.self) private var app
    let next: () -> Void

    var body: some View {
        VStack {
            StepHeader(title: "Let Glide listen and type", subtitle: "Two switches in System Settings. Glide opens the right pane and points at each one.")
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 12) {
                    PermissionRow(
                        granted: app.hasMicrophone, title: app.hasMicrophone ? "Glide can hear you" : "Let Glide hear you",
                        detail: "The microphone is used only while you hold your hotkey.", action: app.requestMicrophone)
                    PermissionRow(
                        granted: app.hasAccessibility, title: "Let Glide paste text",
                        detail: "Accessibility lets it hear your hotkey and type at your cursor.", action: app.guideAccessibility)
                    ModelRow()
                }
                .frame(maxWidth: 380)
                SwitchIllustration()
            }
            Spacer()
            Button("Continue", action: next)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!granted)
        }
        .onChange(of: granted) { _, now in
            guard now else { return }
            Task {
                try? await Task.sleep(for: .seconds(0.8))  // long enough to see both checks
                next()
            }
        }
    }

    private var granted: Bool { app.hasMicrophone && app.hasAccessibility }
}

private struct PermissionRow: View {
    let granted: Bool
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(granted ? Tokens.tint : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted { Button("Enable", action: action) }
        }
        .card(padding: 14)
        .animation(Tokens.spring, value: granted)
    }
}

private struct ModelRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: app.modelProgress == nil ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.title3).foregroundStyle(app.modelProgress == nil ? Tokens.tint : .secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Speech model").font(.headline)
                if app.modelFailed {
                    Text("The download failed. Check your connection and reopen Glide.").font(.callout).foregroundStyle(.secondary)
                } else if let progress = app.modelProgress {
                    Text("Downloading, \(Int(progress * 100))%. It runs on this Mac.").font(.callout).foregroundStyle(.secondary)
                        .monospacedDigit()
                    ProgressView(value: progress)
                } else {
                    Text("Ready. It runs on this Mac.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
    }
}

/// A drawing of the Accessibility list with Glide's switch on.
private struct SwitchIllustration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Accessibility").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 8)
            ForEach(["Terminal", "Glide", "Shortcuts"], id: \.self) { name in
                HStack {
                    if name == "Glide" {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
                    } else {
                        RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(width: 20, height: 20)
                    }
                    Text(name).font(.callout).opacity(name == "Glide" ? 1 : 0.5)
                    Spacer()
                    Capsule().fill(name == "Glide" ? AnyShapeStyle(Tokens.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 30, height: 18)
                        .overlay(alignment: name == "Glide" ? .trailing : .leading) { Circle().fill(.white).padding(2) }
                }
                .padding(.vertical, 8)
                if name != "Shortcuts" { Divider() }
            }
        }
        .frame(width: 208)
        .card(padding: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In System Settings, turn on the switch next to Glide under Accessibility.")
    }
}

private struct MicrophoneStep: View {
    @Environment(AppModel.self) private var app
    @State private var heard: TimeInterval = 0
    @State private var lastLevel = Date.now
    @State private var showHelp = false
    let next: () -> Void

    var body: some View {
        @Bindable var app = app
        VStack {
            StepHeader(title: "Check your microphone", subtitle: "Built-in and wired microphones work best. Bluetooth headsets are less reliable.")
            CheckCard {
                Text(heard >= 1 ? "Glide can hear you" : "Do the bars move when you speak?").font(.title3.weight(.semibold))
                LevelBars(level: app.bar.level)
                if showHelp {
                    Text("Choose another microphone below. A Bluetooth headset may stay silent until it switches to its call microphone, so try the built-in one.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack {
                    Picker("Microphone", selection: $app.microphoneID) {
                        Text("System Default").tag("")
                        ForEach(app.microphones) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: app.microphoneID) {
                        app.stopMicTest()
                        app.startMicTest()
                    }
                    Spacer()
                    Button("No") { showHelp = true }
                    Button("Yes", action: next).buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear {
            app.refreshMicrophones()
            app.startMicTest()
        }
        .onDisappear { app.stopMicTest() }
        // About a second of speech moves on by itself.
        .onChange(of: app.bar.level) { _, level in
            let now = Date.now
            if level > 0.35 { heard += min(now.timeIntervalSince(lastLevel), 0.1) }
            lastLevel = now
        }
        .onChange(of: heard >= 1) { _, enough in if enough { advance() } }
    }

    private func advance() {
        Task {
            try? await Task.sleep(for: .seconds(0.7))
            next()
        }
    }
}

private struct LevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<15, id: \.self) { i in
                let weight = 0.4 + 0.6 * cos(Double(i - 7) / 7 * .pi / 2)
                Capsule().fill(Tokens.tint)
                    .frame(width: 6, height: 6 + 54 * CGFloat(Double(level) * weight))
            }
        }
        .frame(height: 64)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

private struct HotkeyStep: View {
    @Environment(AppModel.self) private var app
    @State private var showHelp = false
    let next: () -> Void

    private var lit: Bool {
        if case .recording = app.bar.state { return true }
        return false
    }

    var body: some View {
        VStack {
            StepHeader(title: "Choose your hotkey", subtitle: "We suggest fn. Hold it to dictate, double-tap to keep recording.")
            CheckCard {
                Text("Does the key light up while you hold it?").font(.title3.weight(.semibold))
                Text("fn").font(.system(size: 28, weight: .medium, design: .rounded))
                    .frame(width: 88, height: 72)
                    .background(RoundedRectangle(cornerRadius: 14).fill(lit ? AnyShapeStyle(Tokens.tint) : AnyShapeStyle(.quaternary)))
                    .foregroundStyle(lit ? .white : .primary)
                    .scaleEffect(lit ? 0.96 : 1)
                    .animation(Tokens.spring, value: lit)
                BarPreview(model: app.bar)
                Text("This is the bar at the edge of your screen. It shows when Glide is listening.")
                    .font(.callout).foregroundStyle(.secondary)
                if showHelp {
                    Text("macOS may be using fn itself. In Keyboard settings, set “Press fn key to” to “Do Nothing”, then try again.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Open Keyboard Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                }
                HStack {
                    Spacer()
                    Button("No") { showHelp = true }
                    Button("Yes", action: next).buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear { app.listenOnly = true }
        .onDisappear { app.listenOnly = false }
        // A full hold and release ends in the bar's tick.
        .onChange(of: app.bar.state) { _, state in
            guard state == .completed else { return }
            Task {
                try? await Task.sleep(for: .seconds(0.8))
                next()
            }
        }
    }
}

private struct TryStep: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var dictated = 0
    let done: () -> Void

    /// Text arrived from a dictation, not from typing.
    private var worked: Bool { dictated > 0 && !text.isEmpty }

    var body: some View {
        VStack {
            StepHeader(title: "Say something", subtitle: "Click in the box, hold fn and speak.")
            CheckCard {
                HStack(spacing: 8) {
                    if worked { Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.tint).transition(.scale.combined(with: .opacity)) }
                    Text(worked ? "That worked" : "Did your words appear?")
                }
                .font(.title3.weight(.semibold))
                .animation(Tokens.spring, value: worked)
                if let progress = app.modelProgress {
                    VStack(spacing: 6) {
                        Text("The speech model is still downloading.").foregroundStyle(.secondary)
                        ProgressView(value: progress)
                    }
                }
                TextField("Try it here", text: $text, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                HStack {
                    Button("Try Again") {
                        text = ""
                        focused = true
                    }
                    Spacer()
                    Button("Start Using Glide", action: done).buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear {
            focused = true
            dictated = 0
        }
        .onChange(of: app.bar.state) { _, state in if state == .completed { dictated += 1 } }
    }
}
