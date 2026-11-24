import Foundation
import GlideCore

/// The rules layer between the recognizer and the paste.
public enum Refiner {
    /// Replaces each heard-as form (whole words, any case) with its dictionary word.
    /// Returns the new text and the ids of entries that matched.
    public static func applyDictionary(_ text: String, entries: [DictionaryEntry]) -> (text: String, used: [UUID]) {
        var result = text
        var used: [UUID] = []
        for entry in entries {
            for form in entry.heardAs where !form.isEmpty {
                let pattern = "(?<![\\w'])" + NSRegularExpression.escapedPattern(for: form) + "(?![\\w'])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                let range = NSRange(result.startIndex..., in: result)
                guard regex.firstMatch(in: result, range: range) != nil else { continue }
                result = regex.stringByReplacingMatches(
                    in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: entry.word))
                used.append(entry.id)
            }
        }
        return (result, used)
    }

    /// Fits `text` onto what is before the cursor: adds a joining space and lowercases the first word mid-sentence.
    /// `isCommonWord` says whether a lowercased word is an ordinary word, so names keep their capital.
    public static func join(_ text: String, after before: String?, isCommonWord: (String) -> Bool) -> String {
        guard let before, let last = before.last, let first = text.first else { return text }
        var text = text
        let opensWord = last.isWhitespace || "([{\"'“‘/-".contains(last)
        if !opensWord && !first.isPunctuation { text = " " + text }

        // Look past spaces and opening brackets or quotes to the character that decides.
        let deciding = before.last { !" \t([{\"'“‘".contains($0) }
        let sentenceEnded = deciding.map { ".!?…:\n".contains($0) } ?? true
        let firstWord = String(text.drop { $0 == " " }.prefix { $0.isLetter || $0 == "'" })
        if !sentenceEnded, firstWord != "I", !firstWord.hasPrefix("I'"), firstWord.dropFirst().allSatisfy(\.isLowercase),
            isCommonWord(firstWord.lowercased()), let index = text.firstIndex(where: \.isLetter)
        {
            text.replaceSubrange(index...index, with: text[index].lowercased())
        }
        return text
    }
}
