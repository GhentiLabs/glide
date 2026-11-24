import AppKit
import ApplicationServices
import AudioCapture
import FieldContext
import GlideCore
import HotkeyEngine
import Inserter
import Overlay
import Recognizer
import Refiner
import Store
import os

/// Runs Glide: hotkey → microphone → Parakeet → rules → paste, plus the state every window reads.
@MainActor @Observable
final class AppModel {
    let store = Store(directory: Store.defaultDirectory)
    let bar = BarModel()
    /// 0...1 while the model downloads or loads; nil once it is ready.
    private(set) var modelProgress: Double? = 0
    private(set) var modelFailed = false
    private(set) var hasAccessibility = AXIsProcessTrusted()
    private(set) var hasMicrophone = AudioRecorder.isAuthorized
    private(set) var microphones = AudioRecorder.microphones
    var paused = false {
        didSet { listener?.setPaused(paused) }
    }
    var microphoneID: String {
        didSet {
            UserDefaults.standard.set(microphoneID, forKey: "microphoneID")
            recorder.microphoneID = microphoneID.isEmpty ? nil : microphoneID
        }
    }
    /// The first-run hotkey check: the key works, but nothing is transcribed.
    var listenOnly = false
    /// Set by the menu bar label, which SwiftUI renders at launch.
    @ObservationIgnored var openWindow: (String) -> Void = { _ in }

    @ObservationIgnored private lazy var barPanel = BarPanel(model: bar)
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let recognizer = ParakeetRecognizer()
    @ObservationIgnored private let cues = Cues()
    @ObservationIgnored private let guide = PermissionGuide()
    @ObservationIgnored private var listener: HotkeyListener?
    @ObservationIgnored private var recording = false
    @ObservationIgnored private var micTesting = false
    @ObservationIgnored private var snapshot: Task<FieldSnapshot?, Never>?
    @ObservationIgnored private var frontApp: String?
    @ObservationIgnored private var lastTranscript: String?
    private let log = Logger(subsystem: "com.ghentilabs.glide", category: "dictation")

    init() {
        microphoneID = UserDefaults.standard.string(forKey: "microphoneID") ?? ""
        recorder.microphoneID = microphoneID.isEmpty ? nil : microphoneID
        Task { await launch() }
    }

    var isSetupDone: Bool { UserDefaults.standard.bool(forKey: "setupDone") }

    var status: String {
        if paused { return "Paused" }
        if !hasAccessibility { return "Needs Accessibility permission" }
        if modelFailed { return "Speech model failed to load" }
        if let modelProgress { return "Getting the speech model ready, \(Int(modelProgress * 100))%" }
        return "Hold fn to dictate"
    }

    func open(_ window: String) {
        NSApp.activate()
        openWindow(window)
    }

    private func launch() async {
        Ducker.restore()  // undo a duck left by a crash
        barPanel.show()
        recorder.onLevel = { [bar] level in Task { @MainActor in bar.push(level: level) } }
        bar.onStop = { [weak self] in self?.endHandsFree(.submit) }
        bar.onCancel = { [weak self] in self?.endHandsFree(.cancel) }
        bar.onOpenSettings = { [weak self] in self?.open("settings") }
        Task { await loadModel() }
        await waitForAccessibility()
    }

    private func loadModel() async {
        modelFailed = false
        do {
            try await recognizer.prepare { [weak self] fraction in
                Task { @MainActor in if self?.modelProgress != nil { self?.modelProgress = fraction } }
            }
            modelProgress = nil
        } catch {
            log.error("model load failed: \(error.localizedDescription, privacy: .public)")
            modelFailed = true
        }
    }

    /// The event tap needs Accessibility. Setup asks for it; after setup a toast offers the guide.
    private func waitForAccessibility() async {
        if !AXIsProcessTrusted() && isSetupDone {
            bar.show(Toast(
                symbol: "hand.raised", title: "Glide needs Accessibility",
                message: "It lets Glide hear your hotkey and type at your cursor.",
                actions: [.init("Open Settings", primary: true) { [weak self] in self?.guideAccessibility() }], duration: 20))
        }
        let listener = HotkeyListener(
            onAction: { [weak self] action in MainActor.assumeIsolated { self?.handle(action) } },
            onPasteLast: { [weak self] in MainActor.assumeIsolated { self?.pasteLast() } })
        while (try? listener.start()) == nil {
            try? await Task.sleep(for: .seconds(1))
        }
        listener.setPaused(paused)
        self.listener = listener
        hasAccessibility = true
    }

    // MARK: Permissions and the microphone check

    func requestMicrophone() {
        Task {
            if await AudioRecorder.requestPermission() {
                hasMicrophone = true
            } else {
                _ = await guide.guide(.microphone) { AudioRecorder.isAuthorized }
                hasMicrophone = AudioRecorder.isAuthorized
            }
        }
    }

    func guideAccessibility() {
        // Registers Glide in the Accessibility list so its switch is there to turn on.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        Task { _ = await guide.guide(.accessibility) { AXIsProcessTrusted() } }
    }

    func refreshMicrophones() { microphones = AudioRecorder.microphones }

    func startMicTest() {
        guard !micTesting, !recording, AudioRecorder.isAuthorized else { return }
        do {
            try recorder.start()
            micTesting = true
        } catch {
            log.error("microphone test failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopMicTest() {
        guard micTesting else { return }
        _ = recorder.stop()
        micTesting = false
        bar.resetLevel()
    }

    // MARK: Dictation

    private func endHandsFree(_ action: HotkeyGesture.Action) {
        listener?.reset()
        handle(action)
    }

    private func handle(_ action: HotkeyGesture.Action) {
        switch action {
        case .start:
            guard !micTesting else { return }
            guard modelProgress == nil else {
                show(.initializing)
                if modelFailed { show(.error(.modelUnavailable)) }
                return
            }
            guard AudioRecorder.isAuthorized else {
                log.error("microphone not authorized")
                return show(.error(.microphoneDenied))
            }
            frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            snapshot = listenOnly ? nil : Task.detached { FieldContext.snapshot() }
            play(.start)
            if UserDefaults.standard.object(forKey: "duckAudio") as? Bool ?? true { Ducker.duck() }
            do {
                try recorder.start()
                recording = true
                bar.resetLevel()
                show(.recording(handsFree: false))
                log.notice("recording from \(self.recorder.deviceName, privacy: .public)")
            } catch {
                Ducker.restore()
                log.error("microphone failed: \(error.localizedDescription, privacy: .public)")
                show(.error(.microphoneDenied))
            }
        case .latchHandsFree:
            if recording { show(.recording(handsFree: true)) }
        case .cancel:
            guard recording else { return show(.idle) }
            log.notice("cancelled")
            _ = recorder.stop()
            recording = false
            Ducker.restore()
            play(.cancel)
            show(.idle)
        case .submit:
            guard recording else { return show(.idle) }
            recording = false
            let samples = recorder.stop()
            Ducker.restore()
            play(.stop)
            Task { await finish(samples, released: .now) }
        }
    }

    private func finish(_ samples: [Float], released: ContinuousClock.Instant) async {
        guard !listenOnly else { return show(.completed) }
        let peak = samples.lazy.map(abs).max() ?? 0
        log.notice("captured \(samples.count / 16) ms, peak \(peak)")
        // A muted or denied microphone records exact silence rather than failing.
        guard peak > 0.0005 else {
            log.error("microphone delivered silence")
            return show(.error(.microphoneDenied))
        }
        show(.transcribing)
        let raw: String
        do {
            raw = try await recognizer.transcribe(samples, context: RecognitionContext())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            log.error("recognition failed: \(error.localizedDescription, privacy: .public)")
            return show(.error(.recognitionFailed(error.localizedDescription)))
        }
        guard !raw.isEmpty else {
            log.notice("recognizer returned no text")
            return show(.error(.nothingHeard))
        }
        let (refined, used) = Refiner.applyDictionary(raw, entries: store.dictionary)
        store.countUses(used)
        let field = await snapshot?.value
        store.add(DictationRecord(app: field?.bundleID ?? frontApp, rawTranscript: raw, refinedText: refined))
        lastTranscript = refined

        if field?.isSecure == true {
            bar.show(Toast(
                symbol: "lock", title: "Glide doesn't type into password fields",
                message: "Your words are saved. Paste them yourself if you meant to.", keycap: "⌃ ⌘ V"))
            return show(.idle)
        }
        guard let field else {
            bar.show(Toast(
                symbol: "text.cursor", title: "No text field in focus",
                message: "Your words are saved. Click where you want them and paste.", keycap: "⌃ ⌘ V", duration: 8))
            return show(.idle)
        }
        let smart = UserDefaults.standard.object(forKey: "smartSpacing") as? Bool ?? true
        let text = smart ? Refiner.join(refined, after: field.before, isCommonWord: Self.isCommonWord) : refined
        Inserter.paste(text)
        log.notice("release to paste: \(Int((ContinuousClock.now - released) / .milliseconds(1))) ms for \(samples.count / 16) ms of audio")
        show(.completed)
        Task { await confirm(text, replacing: field) }
        offerHandsFreeTip()
    }

    /// If the field could be read and did not change, the paste did not land: write through Accessibility instead.
    private func confirm(_ text: String, replacing field: FieldSnapshot) async {
        guard let before = field.value else { return }
        try? await Task.sleep(for: .milliseconds(250))
        let landed = await Task.detached { FieldContext.currentValue() != before }.value
        guard !landed else { return }
        let inserted = await Task.detached { FieldContext.insert(text) }.value
        log.notice("paste did not land; accessibility insert \(inserted ? "worked" : "failed", privacy: .public)")
    }

    private func pasteLast() {
        guard let lastTranscript else {
            return bar.show(Toast(symbol: "text.cursor", title: "Nothing to paste yet", duration: 3))
        }
        Inserter.paste(lastTranscript)
    }

    private func offerHandsFreeTip() {
        guard store.records.count >= 3, !UserDefaults.standard.bool(forKey: "tipHandsFreeShown") else { return }
        UserDefaults.standard.set(true, forKey: "tipHandsFreeShown")
        bar.show(Toast(
            .tip, symbol: "hand.tap", title: "Double-tap to keep recording",
            message: "Tap fn twice and Glide listens until you press it again.", keycap: "fn", duration: 9))
    }

    private func play(_ cue: Cues.Cue) {
        cues.enabled = UserDefaults.standard.object(forKey: "soundsEnabled") as? Bool ?? true
        cues.play(cue)
    }

    private func show(_ state: SessionState) {
        bar.state = state
        if case .error(let error) = state { bar.show(toast(for: error)) }
        switch state {
        case .completed, .error, .initializing:
            Task {
                try? await Task.sleep(for: .seconds(state == .completed ? 0.9 : 1.6))
                if bar.state == state { bar.state = .idle }
            }
        default:
            break
        }
    }

    private func toast(for error: SessionError) -> Toast {
        switch error {
        case .microphoneDenied:
            Toast(
                symbol: "mic.slash", title: "Glide can't hear you",
                message: "Turn on the microphone for Glide in System Settings.",
                actions: [.init("Open Settings", primary: true) { [weak self] in self?.requestMicrophone() }], duration: 10)
        case .accessibilityDenied:
            Toast(
                symbol: "hand.raised", title: "Glide needs Accessibility",
                actions: [.init("Open Settings", primary: true) { [weak self] in self?.guideAccessibility() }], duration: 10)
        case .modelUnavailable:
            Toast(
                symbol: "arrow.down.circle", title: "The speech model isn't ready",
                message: modelFailed ? "It failed to load." : "It's still being set up.",
                actions: modelFailed ? [.init("Try Again", primary: true) { [weak self] in Task { await self?.loadModel() } }] : [])
        case .nothingHeard:
            Toast(symbol: "waveform", title: "Nothing heard", message: "Hold fn while you speak, then let go.", duration: 4)
        case .recognitionFailed(let reason):
            Toast(symbol: "exclamationmark.triangle", title: "Couldn't transcribe that", message: reason)
        case .insertionFailed:
            Toast(symbol: "text.cursor", title: "Couldn't insert the text", keycap: "⌃ ⌘ V")
        }
    }

    /// Lowercase words the spell checker knows are ordinary; names and jargon keep their capital.
    private static func isCommonWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }
}
