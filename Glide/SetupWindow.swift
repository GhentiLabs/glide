import GlideCore
import Overlay
import SwiftUI

/// First run: four steps in one fixed frame. Each shows one thing to try and moves on when it works.
struct SetupWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = 0

    var body: some View {
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
        .transition(.blurReplace)
        .id(step)
        .animation(Tokens.spring, value: step)
        .frame(width: 780, height: 500)
        .background(Tokens.canvas)
        .tint(Tokens.tint)
        .toolbar {
            if step > 0 {
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left") { step -= 1 }
                }
            }
            ToolbarItem(placement: .principal) { StepDots(step: step, count: 4) }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 6) {
                    CaretMark(caret: Tokens.tintGraphic).frame(width: 15, height: 15)
                    Text("Glide").font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.secondary).padding(.trailing, 8)
                .accessibilityElement(children: .ignore).accessibilityLabel("Glide")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .onAppear { NSApp.activate() }
    }
}

/// Four segments; the current one is longer and the finished ones are dimmer.
private struct StepDots: View {
    let step: Int
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == step ? AnyShapeStyle(Tokens.tint) : i < step ? AnyShapeStyle(Tokens.tint.opacity(0.45)) : AnyShapeStyle(.quaternary))
                    .frame(width: i == step ? 22 : 6, height: 6)
            }
        }
        .animation(Tokens.spring, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1) of \(count)")
    }
}

/// The frame every step shares: title, one line of help, a stage, and actions pinned to the bottom.
private struct StepPage<Stage: View, Footer: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let stage: Stage
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary).padding(.top, 6)
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 28)
            HStack(spacing: 10) { footer }
                .controlSize(.large)
                .frame(height: 36)
                .padding(.top, 20)
        }
        .padding(.horizontal, 100).padding(.top, 4).padding(.bottom, 28)
    }
}

/// A status note set like an expression mark in a score, with a tick once the step has worked.
private struct StatusMark: View {
    let text: String
    var done = false

    var body: some View {
        HStack(spacing: 6) {
            if done { Tick().font(.body) }
            Text(text).font(.system(size: 15, design: .serif)).italic().foregroundStyle(done ? .primary : .secondary)
        }
        .animation(Tokens.spring, value: done)
        .accessibilityElement(children: .combine)
    }
}

private struct Tick: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.tint)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
            .accessibilityLabel("Done")
    }
}

/// Help for a step that isn't working, shown from the button that asks.
private struct HelpNote<Action: View>: View {
    let text: String
    @ViewBuilder let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            action
        }
        .frame(width: 260, alignment: .leading)
        .padding(16)
    }
}

// MARK: Permissions

private struct PermissionsStep: View {
    @Environment(AppModel.self) private var app
    let next: () -> Void

    var body: some View {
        StepPage(title: "Let Glide listen and type", subtitle: "Glide needs two permissions to hear you and type for you.") {
            VStack(spacing: 0) {
                SetupRow(symbol: "mic.fill", title: "Microphone", detail: "Glide listens only while you hold your hotkey.") {
                    Grant(done: app.hasMicrophone, label: "Allow", action: app.requestMicrophone)
                }
                Divider().padding(.leading, 76)
                SetupRow(symbol: "accessibility", title: "Accessibility", detail: "Lets Glide hear your hotkey and type at your cursor.") {
                    Grant(done: app.hasAccessibility, label: "Open Settings…", action: app.guideAccessibility)
                }
                Divider().padding(.leading, 76)
                ModelRow()
            }
            .card(padding: 0)
        } footer: {
            Label("Nothing is uploaded. Your audio stays on this Mac.", systemImage: "lock.fill")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Continue", action: next)
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!granted)
        }
        .onChange(of: granted) { _, now in
            guard now else { return }
            Task {
                try? await Task.sleep(for: .seconds(0.8))  // long enough to see both ticks
                next()
            }
        }
    }

    private var granted: Bool { app.hasMicrophone && app.hasAccessibility }
}

private struct SetupRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 22).frame(maxHeight: .infinity)
    }
}

/// The button that asks for a permission, replaced by a tick once it is granted.
private struct Grant: View {
    let done: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        ZStack {
            if done { Tick().font(.title2) } else { Button(label, action: action).transition(.opacity) }
        }
        .animation(Tokens.spring, value: done)
    }
}

private struct ModelRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SetupRow(symbol: "waveform", title: "Speech model", detail: detail) {
            if app.modelFailed {
                Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.red).accessibilityLabel("Failed")
            } else if let progress = app.modelProgress {
                ProgressView(value: progress).frame(width: 72)
            } else {
                Tick().font(.title2)
            }
        }
    }

    private var detail: String {
        if app.modelFailed { return "The download failed. Check your connection and reopen Glide." }
        if let progress = app.modelProgress { return "Downloading, \(Int(progress * 100))%. It runs on this Mac." }
        return "Ready. It runs on this Mac."
    }
}

// MARK: Microphone

private struct MicrophoneStep: View {
    @Environment(AppModel.self) private var app
    @State private var heard: TimeInterval = 0
    @State private var lastLevel = Date.now
    @State private var showHelp = false
    let next: () -> Void

    var body: some View {
        @Bindable var app = app
        StepPage(title: "Check your microphone", subtitle: "Say a few words. The bars should move with your voice.") {
            VStack(spacing: 22) {
                LiveWave(bar: app.bar)
                StatusMark(text: heard >= 1 ? "Glide can hear you" : "Listening", done: heard >= 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card(padding: 0)
        } footer: {
            Picker("Microphone", selection: $app.microphoneID) {
                Text("System Default").tag("")
                ForEach(app.microphones) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().frame(maxWidth: 220)
            .onChange(of: app.microphoneID) {
                app.stopMicTest()
                app.startMicTest()
            }
            Spacer()
            Button("Not Moving?") { showHelp = true }
                .popover(isPresented: $showHelp, arrowEdge: .top) {
                    HelpNote(text: "Choose another microphone from the menu on the left. A Bluetooth headset may stay silent until it switches to its call microphone, so try the built-in one.") {}
                }
            Button("Continue", action: next).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
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

/// The last few seconds of microphone level, newest on the right.
private struct LiveWave: View {
    let bar: BarModel
    @State private var history = [Float](repeating: 0, count: 56)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(history.indices, id: \.self) { i in
                Capsule().fill(Tokens.tintGraphic.opacity(0.25 + 0.75 * Double(i) / Double(history.count - 1)))
                    .frame(width: 4, height: 4 + 104 * CGFloat(history[i]))
            }
        }
        .frame(height: 108)
        .animation(.linear(duration: 0.05), value: history)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                history.removeFirst()
                history.append(bar.level)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(bar.level * 100)) percent")
    }
}

// MARK: Hotkey

private struct HotkeyStep: View {
    @Environment(AppModel.self) private var app
    @State private var showHelp = false
    @State private var heard = false
    let next: () -> Void

    private var lit: Bool {
        if case .recording = app.bar.state { return true }
        return false
    }

    var body: some View {
        StepPage(title: "Hold fn to dictate", subtitle: "Hold it now and say anything. Double-tap to keep recording.") {
            VStack(spacing: 16) {
                FnKey(lit: lit)
                StatusMark(text: heard ? "Glide heard your key" : lit ? "Listening" : "Waiting for fn", done: heard)
            }
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    Text("The bar at the edge of your screen does the same.").font(.callout).foregroundStyle(.secondary)
                    BarPreview(model: app.bar)
                }
            }
            .card(padding: 0)
        } footer: {
            Button("Nothing Happens?") { showHelp = true }
                .popover(isPresented: $showHelp, arrowEdge: .top) {
                    HelpNote(text: "macOS may be using fn itself. In Keyboard settings, set “Press fn key to” to “Do Nothing”, then try again.") {
                        Button("Open Keyboard Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                    }
                }
            Spacer()
            Button("Continue", action: next).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
        .onAppear { app.listenOnly = true }
        .onDisappear { app.listenOnly = false }
        // A full hold and release ends in the bar's tick.
        .onChange(of: app.bar.state) { _, state in
            guard state == .completed else { return }
            heard = true
            Task {
                try? await Task.sleep(for: .seconds(0.8))
                next()
            }
        }
    }
}

/// The fn key as it looks on a Mac keyboard. It sinks and lights while held.
private struct FnKey: View {
    let lit: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            Text("fn").font(.system(size: 19, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            Image(systemName: "globe").font(.system(size: 17, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .padding(12)
        .frame(width: 88, height: 88)
        // Dark ink on the lit key: white fails contrast on the Dark Mode tint.
        .foregroundStyle(lit ? AnyShapeStyle(Color(red: 0.16, green: 0.07, blue: 0.02)) : AnyShapeStyle(.primary))
        // Opaque fills: the cap covers its side as it sinks.
        .background(shape.fill(lit ? Tokens.tintGraphic : Tokens.cardFill.mix(with: .primary, by: 0.16)))
        .overlay(shape.strokeBorder(.primary.opacity(lit ? 0 : 0.1)))
        .offset(y: lit ? 4 : 0)
        .background(shape.fill(Tokens.cardFill.mix(with: .black, by: 0.3)).offset(y: 5))
        .animation(Tokens.spring, value: lit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lit ? "fn key, held" : "fn key")
    }
}

// MARK: First dictation

private struct TryStep: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var dictated = 0
    let done: () -> Void

    /// Text arrived from a dictation, not from typing.
    private var worked: Bool { dictated > 0 && !text.isEmpty }

    var body: some View {
        StepPage(title: "Say something", subtitle: "Click in the box, hold fn and speak.") {
            VStack(alignment: .leading, spacing: 14) {
                if let progress = app.modelProgress {
                    HStack(spacing: 10) {
                        Text("The speech model is still downloading.").font(.callout).foregroundStyle(.secondary)
                        ProgressView(value: progress).frame(width: 96)
                    }
                }
                TextField("Your words appear here", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 17)).lineSpacing(3)
                    .focused($focused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(22)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .card(padding: 0)
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.cardRadius).strokeBorder(Tokens.tint.opacity(focused ? 0.8 : 0), lineWidth: 1.5)
            }
            .animation(Tokens.spring, value: focused)
        } footer: {
            if worked { StatusMark(text: "That worked", done: true).transition(.opacity) }
            Spacer()
            Button("Try Again") {
                text = ""
                focused = true
            }
            .disabled(text.isEmpty)
            Button("Start Using Glide", action: done).buttonStyle(.borderedProminent)
        }
        .animation(Tokens.spring, value: worked)
        .onAppear {
            focused = true
            dictated = 0
        }
        .onChange(of: app.bar.state) { _, state in if state == .completed { dictated += 1 } }
    }
}
