import Foundation
import Testing
@testable import AudioCapture

@Suite struct OpusTests {
    @Test func compressesAndComesBackTheSameLength() throws {
        // Two seconds of a 440 Hz tone at 16 kHz.
        let samples = (0..<32_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.5 }
        let data = try Opus.encode(samples)
        #expect(data.count < samples.count * 4 / 10)  // well under a tenth of the raw Float32 size
        let back = try Opus.decode(data)
        #expect(abs(back.count - samples.count) < 1_600)  // within 0.1 s; Opus pads to whole frames
        let energy = back.reduce(0) { $0 + $1 * $1 } / Float(back.count)
        #expect(energy > 0.05)  // the tone survived (its true mean square is 0.125)
    }
}
