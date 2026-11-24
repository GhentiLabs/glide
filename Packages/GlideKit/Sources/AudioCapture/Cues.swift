@preconcurrency import AVFoundation

/// Glide's four sound cues, synthesized so there are no audio files to ship.
@MainActor
public final class Cues {
    public enum Cue: CaseIterable { case start, stop, cancel, learned }

    /// Set false to mute every cue.
    public var enabled = true

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private lazy var buffers: [Cue: AVAudioPCMBuffer] = Dictionary(
        uniqueKeysWithValues: Cue.allCases.map { ($0, render($0)) })

    public init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    public func play(_ cue: Cue) {
        guard enabled, let buffer = buffers[cue] else { return }
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }

    /// Notes as (frequency, start, length) in Hz and seconds.
    private func notes(_ cue: Cue) -> [(Double, Double, Double)] {
        switch cue {
        case .start: [(784, 0, 0.09), (1047, 0.06, 0.12)]
        case .stop: [(1047, 0, 0.08), (784, 0.05, 0.12)]
        case .cancel: [(440, 0, 0.16)]
        case .learned: [(784, 0, 0.1), (988, 0.05, 0.1), (1175, 0.1, 0.18)]
        }
    }

    private func render(_ cue: Cue) -> AVAudioPCMBuffer {
        let notes = notes(cue)
        let length = notes.map { $0.1 + $0.2 }.max()! + 0.02
        let frames = AVAudioFrameCount(length * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / format.sampleRate
            var sample = 0.0
            for (frequency, start, duration) in notes where t >= start && t < start + duration {
                let local = t - start
                let envelope = min(local / 0.005, 1) * exp(-local / (duration / 3))  // 5 ms attack, soft decay
                sample += sin(2 * .pi * frequency * local) * envelope
            }
            out[i] = Float(sample * (cue == .cancel ? 0.12 : 0.16))
        }
        return buffer
    }
}
