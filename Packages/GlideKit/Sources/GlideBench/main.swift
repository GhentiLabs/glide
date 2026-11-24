import FluidAudio
import Foundation
import GlideCore
import Recognizer

// Usage: glide-bench <folder>
// The folder holds clips (wav, m4a, ...) each with a same-named .txt reference transcript.
// Prints WER per clip and overall, and recognition time.

guard CommandLine.arguments.count == 2 else {
    print("usage: glide-bench <folder of clips with matching .txt references>")
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
let clips = files.filter { $0.pathExtension != "txt" && !$0.lastPathComponent.hasPrefix(".") }
    .filter { FileManager.default.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("txt").path) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !clips.isEmpty else {
    print("no clips with matching .txt references in \(folder.path)")
    exit(1)
}

let recognizer = ParakeetRecognizer()
try await recognizer.prepare { _ in }
let converter = AudioConverter()
var errors = 0
var words = 0
var times: [Double] = []
for clip in clips {
    let reference = try String(contentsOf: clip.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
    let samples = try converter.resampleAudioFile(clip)
    let start = ContinuousClock.now
    let text = try await recognizer.transcribe(samples, context: RecognitionContext())
    let seconds = (ContinuousClock.now - start) / .seconds(1)
    let ref = normalizedWords(reference)
    let distance = wordEditDistance(ref, normalizedWords(text))
    errors += distance
    words += ref.count
    times.append(seconds)
    print(String(format: "%@  WER %5.1f%%  %4.0f ms  %@", clip.lastPathComponent,
        100 * Double(distance) / Double(max(ref.count, 1)), seconds * 1000, text))
}
times.sort()
print(String(format: "\n%d clips  WER %.2f%%  median %.0f ms  slowest %.0f ms",
    clips.count, 100 * Double(errors) / Double(max(words, 1)), times[times.count / 2] * 1000, times.last! * 1000))
