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

    /// Without this the microphone delivers silence rather than an error.
    public static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// The microphone to record from, by Core Audio UID; nil follows the system default.
    public var microphoneID: String?

    public var deviceName: String {
        (microphoneID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio))?.localizedName ?? "none"
    }

    public static var microphones: [Microphone] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }

    public func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        let input = engine.inputNode
        if let microphoneID, var device = Self.deviceID(forUID: microphoneID), let unit = input.audioUnit {
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                UInt32(MemoryLayout<AudioDeviceID>.size))
        }
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

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    func consume(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outFormat: AVAudioFormat) {
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

public struct Microphone: Identifiable, Hashable, Sendable {
    /// Core Audio device UID.
    public let id: String
    public let name: String
}
