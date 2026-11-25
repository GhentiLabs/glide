import Foundation
import GlideCore

/// The rules layer between the recognizer and the paste. Misheard words are not fixed here: the vocabulary boosts them during decoding.
public enum Refiner {
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
