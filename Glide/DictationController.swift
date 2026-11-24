import AppKit
import ApplicationServices
import AudioCapture
import GlideCore
import HotkeyEngine
import Inserter
import Overlay
import Recognizer
import os

/// Runs one dictation at a time: hotkey → microphone → Parakeet → paste.
@MainActor @Observable
final class DictationController {
    private(set) var status = "Starting…"

    private let bar = BarModel()
    @ObservationIgnored private lazy var barPanel = BarPanel(model: bar)
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let recognizer = ParakeetRecognizer()
    @ObservationIgnored private var listener: HotkeyListener?
    @ObservationIgnored private var modelReady = false
    @ObservationIgnored private var recording = false
    private let log = Logger(subsystem: "com.ghentilabs.glide", category: "dictation")

    init() {
        Task { await launch() }
    }

    private func launch() async {
        barPanel.show()
        recorder.onLevel = { [bar] level in Task { @MainActor in bar.push(level: level) } }
        _ = await AudioRecorder.requestPermission()
        await startHotkey()
        status = "Loading speech model…"
        do {
            try await recognizer.prepare { [weak self] fraction in
                Task { @MainActor in self?.status = "Downloading speech model \(Int(fraction * 100))%" }
            }
            modelReady = true
            status = "Hold fn to dictate"
        } catch {
            log.error("model load failed: \(error.localizedDescription, privacy: .public)")
            status = "Speech model failed to load"
            show(.error(.modelUnavailable))
        }
    }

    /// The event tap needs Accessibility; ask once, then wait for the grant.
    private func startHotkey() async {
        let prompt = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt, which Swift 6 flags as shared mutable state
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        let listener = HotkeyListener { [weak self] action in
            MainActor.assumeIsolated { self?.handle(action) }
        }
        while true {
            do {
                try listener.start()
                self.listener = listener
                return
            } catch {
                status = "Allow Glide in Accessibility settings"
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func handle(_ action: HotkeyGesture.Action) {
        switch action {
        case .start:
            guard modelReady else { return show(.initializing) }
            do {
                try recorder.start()
                recording = true
                bar.resetLevels()
                show(.recording(handsFree: false))
            } catch {
                log.error("microphone failed: \(error.localizedDescription, privacy: .public)")
                show(.error(.microphoneDenied))
            }
        case .latchHandsFree:
            if recording { show(.recording(handsFree: true)) }
        case .cancel:
            if recording { _ = recorder.stop() }
            recording = false
            show(.idle)
        case .submit:
            guard recording else { return show(.idle) }
            recording = false
            let samples = recorder.stop()
            Task { await finish(samples, released: .now) }
        }
    }

    private func finish(_ samples: [Float], released: ContinuousClock.Instant) async {
        show(.transcribing)
        do {
            let text = try await recognizer.transcribe(samples, context: RecognitionContext())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return show(.error(.nothingHeard)) }
            await Inserter.paste(text)
            let ms = (ContinuousClock.now - released) / .milliseconds(1)
            log.info("release to paste: \(Int(ms)) ms for \(samples.count / 16) ms of audio")
            show(.completed)
        } catch {
            log.error("recognition failed: \(error.localizedDescription, privacy: .public)")
            show(.error(.recognitionFailed(error.localizedDescription)))
        }
    }

    private func show(_ state: SessionState) {
        bar.state = state
        switch state {
        case .completed, .error, .initializing:
            Task {
                try? await Task.sleep(for: .seconds(1))
                if bar.state == state { bar.state = .idle }
            }
        default:
            break
        }
    }
}
