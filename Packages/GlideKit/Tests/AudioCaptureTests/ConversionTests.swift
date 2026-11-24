import AVFoundation
import Testing
@testable import AudioCapture

@Suite struct ConversionTests {
    /// One second of 48 kHz audio in 1024-frame buffers should come out as about 16 000 samples with the signal intact.
    @Test func resamples48kTo16k() throws {
        let inFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = try #require(AVAudioConverter(from: inFormat, to: outFormat))
        let recorder = AudioRecorder()
        var phase = 0.0
        for _ in 0..<47 {
            let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 1024)!
            buffer.frameLength = 1024
            for i in 0..<1024 {
                buffer.floatChannelData![0][i] = Float(0.5 * sin(phase))
                phase += 2 * .pi * 440 / 48_000
            }
            recorder.consume(buffer, converter: converter, outFormat: outFormat)
        }
        let samples = recorder.stop()
        #expect(abs(samples.count - 16_043) < 400, "got \(samples.count)")
        #expect((samples.map(abs).max() ?? 0) > 0.4)
    }
}
