import FluidAudio
import Foundation
import GlideCore
import Learning
import Recognizer

// Usage: glide-bench <folder>
// The folder holds clips (wav, m4a, ...) each with a same-named .txt reference transcript.
// Prints WER per clip and overall, and recognition time.
// GLIDE_VOCAB="word,word" boosts those words, to compare against a run without it.
//
// Usage: glide-bench labels <pairs.jsonl>
// Each line is {"pasted": ..., "final": ..., "raw": optional}. Prints every labelled span, then counts per label,
// for checking the labeller's precision by hand. Keep personal pairs on this Mac.

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "labels" {
    struct Pair: Decodable { var raw: String?; var pasted: String; var final: String }
    var counts: [EditSpan.Kind: Int] = [:]
    let lines = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).split(separator: "\n")
    for (n, line) in lines.enumerated() {
        let pair = try JSONDecoder().decode(Pair.self, from: Data(line.utf8))
        for span in Labeller.label(raw: pair.raw ?? pair.pasted, pasted: pair.pasted, final: pair.final) {
            counts[span.kind, default: 0] += 1
            print("\(n)\t\(span.kind.rawValue)\t\(span.before)\t→\t\(span.after)")
        }
    }
    print(counts.sorted { $0.value > $1.value }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", "))
    exit(0)
}

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
if let vocab = ProcessInfo.processInfo.environment["GLIDE_VOCAB"] {
    try await recognizer.setVocabulary(vocab.split(separator: ",").map { DictionaryEntry(word: String($0)) })
}
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
