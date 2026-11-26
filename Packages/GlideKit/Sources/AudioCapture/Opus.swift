import AVFoundation
import Foundation

/// Compresses a dictation to Opus in a CAF container with the system encoder: about 3 KB a second at 24 kbit/s.
public enum Opus {
    public enum OpusError: Error { case encodeFailed, decodeFailed }

    /// `samples` are 16 kHz mono Float32, as the recorder delivers them.
    public static func encode(_ samples: [Float], sampleRate: Double = 16_000) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatOpus, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24_000,
        ]
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw OpusError.encodeFailed }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        do {
            // The file finishes writing when it is released, so it lives only inside this scope.
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return withoutPadding(try Data(contentsOf: url))
    }

    /// The CAF writer reserves a large `free` chunk for header growth; a finished file doesn't need it.
    static func withoutPadding(_ caf: Data) -> Data {
        guard caf.count > 8, caf.prefix(4) == Data("caff".utf8) else { return caf }
        var out = caf.prefix(8)
        var i = caf.startIndex + 8
        while i + 12 <= caf.endIndex {
            let type = caf[i..<i + 4]
            let size = caf[i + 4..<i + 12].reduce(Int64(0)) { $0 << 8 | Int64($1) }
            // A size of -1 means the chunk (always `data`) runs to the end of the file.
            let end = size < 0 ? caf.endIndex : min(caf.endIndex, i + 12 + Int(size))
            if type != Data("free".utf8) { out += caf[i..<end] }
            i = end
        }
        return Data(out)
    }

    /// Back to 16 kHz mono Float32.
    public static func decode(_ data: Data) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw OpusError.decodeFailed
        }
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
