import AppKit
import ApplicationServices
import AudioCapture
import EditTracker
import FieldContext
import GlideCore
import HotkeyEngine
import Inserter
import Learning
import Overlay
import Recognizer
import Refiner
import Store
import os

/// Runs Glide: hotkey → microphone → Fluid Speech Pro → rules → paste → edit tracking, plus the state every window reads.
@MainActor @Observable
final class AppModel {
    let store = Store(directory: Store.defaultDirectory)
    let bar = BarModel()
    /// 0...1 while the model downloads or loads; nil once it is ready.
    private(set) var modelProgress: Double? = 0 {
        didSet { bar.progress = modelProgress }
    }
    private(set) var modelFailed = false
    private(set) var hasAccessibility = AXIsProcessTrusted()
    private(set) var hasMicrophone = AudioRecorder.isAuthorized
    private(set) var microphones = AudioRecorder.microphones
    var paused = false {
        didSet {
            listener?.setPaused(paused)
            bar.paused = paused
        }
    }
    var microphoneID: String {
        didSet {
            UserDefaults.standard.set(microphoneID, forKey: "microphoneID")
            recorder.microphoneID = microphoneID.isEmpty ? nil : microphoneID
        }
    }
    /// The app the user last worked in, named in the Home headline.
    private(set) var lastApp: NSRunningApplication?
    /// Getting-started tasks Home ticks off.
    var usedHandsFree = UserDefaults.standard.bool(forKey: "usedHandsFree") {
        didSet { UserDefaults.standard.set(usedHandsFree, forKey: "usedHandsFree") }
    }
    var usedPasteLast = UserDefaults.standard.bool(forKey: "usedPasteLast") {
        didSet { UserDefaults.standard.set(usedPasteLast, forKey: "usedPasteLast") }
    }
    /// The first-run hotkey check: the key works, but nothing is transcribed.
    var listenOnly = false
    /// Set by the menu bar label, which SwiftUI renders at launch.
    @ObservationIgnored var openWindow: (String) -> Void = { _ in }

    @ObservationIgnored private lazy var barPanel = BarPanel(model: bar)
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let recognizer = SpeechRecognizer()
    @ObservationIgnored private let cues = Cues()
    @ObservationIgnored private let guide = PermissionGuide()
    @ObservationIgnored private var listener: HotkeyListener?
    @ObservationIgnored private var recording = false
    @ObservationIgnored private var micTesting = false
    @ObservationIgnored private var snapshot: Task<FieldSnapshot?, Never>?
    @ObservationIgnored private var frontApp: String?
    @ObservationIgnored private var lastTranscript: String?
    /// Watches the field after the last paste; a new dictation cancels it.
    @ObservationIgnored private var tracking: Task<Void, Never>?
    private let log = Logger(subsystem: "com.ghentilabs.glide", category: "dictation")

    init() {
        microphoneID = UserDefaults.standard.string(forKey: "microphoneID") ?? ""
        recorder.microphoneID = microphoneID.isEmpty ? nil : microphoneID
        lastApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if app?.bundleIdentifier != Bundle.main.bundleIdentifier { self?.lastApp = app } }
        }
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
        store.onVocabularyChange = { [weak self] in self?.boost($0) }
        boost(store.dictionary)
        Task { await loadModel() }
        await waitForAccessibility()
    }

    func retryModel() { Task { await loadModel() } }

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
            if let modelProgress {
                if modelFailed { return show(.error(.modelUnavailable)) }
                show(.initializing)
                return bar.show(Toast(
                    symbol: "arrow.down.circle", title: "Glide is almost ready",
                    message: "The speech model is \(Int(modelProgress * 100))% loaded.", duration: 4))
            }
            guard AudioRecorder.isAuthorized else {
                log.error("microphone not authorized")
                return show(.error(.microphoneDenied))
            }
            frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            tracking?.cancel()
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
            if recording {
                show(.recording(handsFree: true))
                if !listenOnly { usedHandsFree = true }
            }
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
        let field = await snapshot?.value
        let smart = UserDefaults.standard.object(forKey: "smartSpacing") as? Bool ?? true
        let text = smart && field?.isSecure == false ? Refiner.join(raw, after: field?.before, isCommonWord: Self.isCommonWord) : raw
        let record = DictationRecord(app: field?.bundleID ?? frontApp, rawTranscript: raw, refinedText: text.trimmingCharacters(in: .whitespaces))
        store.add(record)
        lastTranscript = raw

        if field?.isSecure == true {
            skip(record.id, .passwordField)
            bar.show(Toast(
                symbol: "lock", title: "Glide doesn't type into password fields",
                message: "Your words are saved. Paste them yourself if you meant to.", keycap: "⌃ ⌘ V"))
            return show(.idle)
        }
        guard let field else {
            skip(record.id, .fieldUnreadable)
            bar.show(Toast(
                symbol: "text.cursor", title: "No text field in focus",
                message: "Your words are saved. Click where you want them and paste.", keycap: "⌃ ⌘ V", duration: 8))
            return show(.idle)
        }
        log.notice("release to paste: \(Int((ContinuousClock.now - released) / .milliseconds(1))) ms for \(samples.count / 16) ms of audio")
        show(.completed)
        offerHandsFreeTip()
        let before = field.value == nil ? nil : await Task.detached { FieldContext.currentValue() }.value
        let read = await Inserter.paste(text)
        await confirmPaste(text, before: before, read: read)
        track(record.id, pasted: text)
    }

    // MARK: Learning from edits

    /// Follows the field after a paste and stores what the user left there.
    private func track(_ id: UUID, pasted: String) {
        guard UserDefaults.standard.object(forKey: "learnFromEdits") as? Bool ?? true else { return skip(id, .learningOff) }
        let returns: @Sendable () -> Int = { [listener] in listener?.returnCount ?? 0 }
        tracking = Task { [weak self] in
            guard let field = await Task.detached(operation: { FieldContext.trackedField() }).value else {
                self?.skip(id, .fieldUnreadable)
                return
            }
            let result = await EditTracker.track(pasted: pasted, returns: returns) {
                // Reading a field while its app is in the background would follow edits the user isn't making.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == field.pid else { return .paused }
                switch FieldContext.read(field) {
                case .text(let text, let cursor): return .text(text, cursor: cursor)
                case .failed: return .failed
                case .gone: return .gone
                }
            }
            self?.settle(id, result, kind: field.kind)
        }
    }

    private func settle(_ id: UUID, _ result: EditTracker.Result, kind: FieldKind) {
        guard let record = store.records.first(where: { $0.id == id }) else { return }
        let spans = result.final.map { Labeller.label(raw: record.rawTranscript, pasted: record.refinedText, final: $0) } ?? []
        store.setFinal(
            id, text: result.final, source: .field, diff: spans, labellerVersion: Labeller.version, fieldKind: kind,
            skipReason: result.skipReason)
        log.notice("""
            tracked \(kind.rawValue, privacy: .public): \(result.outcome?.rawValue ?? result.skipReason?.rawValue ?? "", privacy: .public), \
            \(spans.count) spans \(spans.map(\.kind.rawValue).joined(separator: " "), privacy: .public)
            """)
        if store.records.first(where: { $0.id == id })?.finalSource == .field { learn(from: id, spans: spans, announce: true) }
    }

    private func skip(_ id: UUID, _ reason: SkipReason) {
        store.setFinal(id, text: nil, source: .field, diff: [], labellerVersion: Labeller.version, skipReason: reason)
    }

    /// The user's own fix in history. It replaces what the tracker saw, and takes back words learned from the old version.
    func correct(_ id: UUID, to text: String) {
        guard let record = store.records.first(where: { $0.id == id }) else { return }
        let spans = Labeller.label(raw: record.rawTranscript, pasted: record.refinedText, final: text)
        store.forgetWords(learnedFrom: id)
        store.setFinal(id, text: text, source: .history, diff: spans, labellerVersion: Labeller.version)
        if record.excluded != true { learn(from: id, spans: spans, announce: false) }
    }

    /// "Not a Correction" keeps the record out of learning and takes back what it taught.
    func setExcluded(_ id: UUID, _ excluded: Bool) {
        store.exclude(id, excluded)
        if excluded {
            store.forgetWords(learnedFrom: id)
        } else if let record = store.records.first(where: { $0.id == id }) {
            learn(from: id, spans: record.diff, announce: false)
        }
    }

    /// Adds the unusual words from misheard spans to the vocabulary, which boosts them from the next dictation on.
    private func learn(from id: UUID, spans: [EditSpan], announce: Bool) {
        var added: [DictionaryEntry] = []
        for (word, heard) in Labeller.vocabulary(from: spans, isCommonWord: Self.isCommonWord) {
            if var known = store.dictionary.first(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
                if !known.heardAs.contains(where: { $0.caseInsensitiveCompare(heard) == .orderedSame }) {
                    known.heardAs.append(heard)
                    store.upsert(known)
                }
                continue
            }
            let entry = DictionaryEntry(word: word, heardAs: [heard], source: .learned, record: id)
            store.upsert(entry)
            added.append(entry)
        }
        guard announce, let first = added.first else { return }
        let ids = Set(added.map(\.id))
        bar.show(Toast(
            symbol: "sparkles", title: added.count == 1 ? "Learned \(first.word)" : "Learned \(added.count) words",
            message: added.count == 1 ? "Glide will listen for it from now on." : added.map(\.word).joined(separator: ", "),
            actions: [.init("Undo") { [weak self] in self?.store.remove(entries: ids) }], duration: 6))
    }

    private func boost(_ entries: [DictionaryEntry]) {
        Task { [recognizer, log] in
            do { try await recognizer.setVocabulary(entries) } catch {
                log.error("vocabulary boosting unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A paste that landed changes the field. If a readable field is still unchanged a second later, the paste was lost
    /// (the app read the clipboard but inserted nothing, or never read it), so the text goes in through Accessibility.
    private func confirmPaste(_ text: String, before: String?, read: Bool) async {
        guard let before else { return log.notice("paste \(read ? "read" : "never read", privacy: .public); field unreadable, not confirmed") }
        let started = ContinuousClock.now
        while ContinuousClock.now - started < .seconds(1) {
            if await Task.detached(operation: { FieldContext.currentValue() }).value != before {
                return log.notice("paste landed after \(Int((ContinuousClock.now - started) / .milliseconds(1))) ms")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let inserted = await Task.detached { FieldContext.insert(text) }.value
        log.notice("paste \(read ? "was read but" : "was never read and", privacy: .public) didn't land; accessibility insert \(inserted ? "worked" : "failed", privacy: .public)")
    }

    private func pasteLast() {
        guard let lastTranscript else {
            return bar.show(Toast(symbol: "text.cursor", title: "Nothing to paste yet", duration: 3))
        }
        usedPasteLast = true
        Task { await Inserter.paste(lastTranscript) }
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
                actions: modelFailed ? [.init("Try Again", primary: true) { [weak self] in self?.retryModel() }] : [])
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
