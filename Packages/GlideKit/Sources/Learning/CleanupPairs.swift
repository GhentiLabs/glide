import Foundation
import GlideCore

extension Labeller {
    /// Fewer corrections than this is too little to learn from.
    public static let minimumCorrections = 5

    /// What the cleanup model can learn from history, oldest first: each transcript with the text the user kept.
    /// Corrections are edits that only fix cleanup, formatting or words the cleanup model wrongly dropped; misheard words,
    /// rewrites and additions are left out, since the model can't know them from the transcript. Dictations kept as pasted
    /// are mixed in, up to twice as many as the corrections, so the add-on doesn't forget what already worked.
    public static func cleanupPairs(from records: [DictationRecord]) -> [(input: String, target: String)] {
        let teaches: Set<EditSpan.Kind> = [.cleanup, .formatting, .restored]
        let usable = records.filter { $0.excluded != true && !$0.rawTranscript.isEmpty }
        let corrections = usable.filter { $0.verdict == .edited && $0.finalText != nil && !$0.diff.isEmpty && $0.diff.allSatisfy { teaches.contains($0.kind) } }
        guard corrections.count >= minimumCorrections else { return [] }
        let kept = usable.filter { $0.verdict == .untouched }.sorted { $0.time > $1.time }.prefix(2 * corrections.count)
        return (corrections + kept).sorted { $0.time < $1.time }.map { record in
            var target = (record.finalText ?? record.refinedText).trimmingCharacters(in: .whitespacesAndNewlines)
            // Pasting mid-sentence lowercases the first word; the model works on the transcript alone, so undo that.
            if record.rawTranscript.first?.isUppercase == true, let first = target.first, first.isLowercase {
                target = first.uppercased() + target.dropFirst()
            }
            return (record.rawTranscript, target)
        }
    }
}
