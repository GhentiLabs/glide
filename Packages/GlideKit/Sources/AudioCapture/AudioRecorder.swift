@preconcurrency import AVFoundation

/// Records the default microphone as 16 kHz mono Float32.
public final class AudioRecorder: @unchecked Sendable {
    public static let sampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Called on the audio thread with the RMS of each buffer.
    public var onLevel: (@Sendable (Float) -> Void)?

    public init() {}

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw CocoaError(.featureUnsupported)
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.consume(buffer, converter: converter, outFormat: outFormat)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// Stops and returns everything recorded since `start`.
    public func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock { samples }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outFormat: AVAudioFormat) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var fed = false  // the input block runs synchronously inside convert
        converter.convert(to: out, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let data = out.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
        if let onLevel, !chunk.isEmpty {
            onLevel((chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot())
        }
    }
}
