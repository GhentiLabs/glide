import GlideCore

/// Turns what Glide heard, what it pasted and what the user kept into labelled edit spans.
/// Each label decides which model a span may teach, so `misheard` is tuned for precision: a wrong one teaches a wrong word.
public enum Labeller {
    /// Stored on each record so labels can be rebuilt when the rules change.
    public static let version = 1
    /// Phonetic similarity a replacement needs to count as misheard.
    static let soundsAlike = 0.6
    /// Longer replacements are treated as rewrites.
    static let maxMisheardWords = 5

    public static func label(raw: String, pasted: String, final: String) -> [EditSpan] {
        let a = words(pasted), b = words(final)
        let refinerChanged = folded(raw) != folded(pasted)
        let rawWords = words(raw).map(plain)
        func span(_ p: Range<Int>, _ f: Range<Int>, _ kind: EditSpan.Kind) -> EditSpan {
            EditSpan(pastedWords: p, finalWords: f, before: a[p].joined(separator: " "), after: b[f].joined(separator: " "), kind: kind)
        }

        func labelRun(_ p: Range<Int>, _ f: Range<Int>) -> [EditSpan] {
            let before = Array(a[p]), after = Array(b[f])
            if before.isEmpty && after.isEmpty { return [] }
            if refinerChanged, !after.isEmpty, contains(rawWords, after.map(plain)), !contains(a.map(plain), after.map(plain)) {
                return [span(p, f, .restored)]
            }
            if folded(before.joined(separator: " ")) == folded(after.joined(separator: " ")) { return [span(p, f, .formatting)] }
            if after.isEmpty { return [span(p, f, isCleanup(p, in: a) ? .cleanup : .rewrite)] }
            if before.isEmpty { return [span(p, f, .addition)] }
            // A fix plus a few extra words lands in one run; split off the extra words if the rest sounds alike.
            guard let split = misheardSplit(before, after) else { return [span(p, f, .rewrite)] }
            let m = (f.lowerBound + split.lowerBound)..<(f.lowerBound + split.upperBound)
            if m == f { return [span(p, f, .misheard)] }
            return [span(p.lowerBound..<p.lowerBound, f.lowerBound..<m.lowerBound, .addition)].filter { !$0.finalWords.isEmpty }
                + trimmed(p, m)
                + [span(p.upperBound..<p.upperBound, m.upperBound..<f.upperBound, .addition)].filter { !$0.finalWords.isEmpty }
        }

        /// Words at either end that differ only in punctuation or case ("done." to "done today.") are formatting,
        /// so they can't drag the words beside them into a false match.
        func trimmed(_ run: Range<Int>, _ runF: Range<Int>) -> [EditSpan] {
            if folded(a[run].joined(separator: " ")) == folded(b[runF].joined(separator: " ")) { return [span(run, runF, .formatting)] }
            let same = { (i: Int, j: Int) in folded(a[i]) == folded(b[j]) && !folded(a[i]).isEmpty }
            var head = 0, tail = 0
            while head < min(run.count, runF.count), same(run.lowerBound + head, runF.lowerBound + head) { head += 1 }
            while tail < min(run.count, runF.count) - head, same(run.upperBound - 1 - tail, runF.upperBound - 1 - tail) { tail += 1 }
            let p = (run.lowerBound + head)..<(run.upperBound - tail)
            let f = (runF.lowerBound + head)..<(runF.upperBound - tail)
            var spans: [EditSpan] = []
            if head > 0 { spans.append(span(run.lowerBound..<p.lowerBound, runF.lowerBound..<f.lowerBound, .formatting)) }
            spans += labelRun(p, f)
            if tail > 0 { spans.append(span(p.upperBound..<run.upperBound, f.upperBound..<runF.upperBound, .formatting)) }
            return spans
        }

        return changedRuns(a, b).flatMap { trimmed($0.pasted, $0.final) }
    }

    /// Words worth adding to the vocabulary: the corrected side of misheard spans that holds a name or a word the model is unlikely to know.
    /// `isCommonWord` gets a lowercased word. Short terms are left out because boosting ignores them.
    public static func vocabulary(from spans: [EditSpan], isCommonWord: (String) -> Bool) -> [(word: String, heardAs: String)] {
        spans.filter { $0.kind == .misheard }.compactMap { span in
            let word = span.after.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            let heard = span.before.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            // Capitalised where Glide wrote it lowercase is a name, even if the spell checker knows the word.
            let madeCapital = word.first?.isUppercase == true && heard.first?.isLowercase == true
            let unusual = madeCapital || word.split(separator: " ").contains { w in
                w.dropFirst().contains(where: \.isUppercase) || w.contains(where: \.isNumber) || !isCommonWord(w.lowercased())
            }
            guard unusual, word.count >= 4, word.lowercased() != heard.lowercased() else { return nil }
            return (word, heard)
        }
    }

    // MARK: Diff

    /// Splits on whitespace and keeps punctuation on its word, so a changed comma is a change.
    static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// Runs of words that differ, from a longest-common-subsequence alignment.
    static func changedRuns(_ a: [String], _ b: [String]) -> [(pasted: Range<Int>, final: Range<Int>)] {
        // lcs[i][j] = common length of a[i...] and b[j...]
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var runs: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0, start: (Int, Int)?
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                if let s = start { runs.append((s.0..<i, s.1..<j)); start = nil }
                i += 1; j += 1
            } else {
                if start == nil { start = (i, j) }
                if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] { j += 1 } else { i += 1 }
            }
        }
        if let s = start { runs.append((s.0..<a.count, s.1..<b.count)) }
        return runs
    }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<$0 + needle.count]) == needle }
    }

    // MARK: Formatting

    /// Lowercase alphanumerics with spaces removed and small numbers as digits: "Twenty two front-end" and "22 frontend" match.
    static func folded(_ text: String) -> String {
        var out = ""
        var pendingTens: Int?
        for word in words(text.lowercased().replacingOccurrences(of: "%", with: " percent ").replacingOccurrences(of: "&", with: " and ")) {
            let w = plain(word)
            if let n = numbers[w] {
                if let t = pendingTens, n < 10 { out += String(t + n); pendingTens = nil; continue }
                if let t = pendingTens { out += String(t) }
                if n >= 20 { pendingTens = n } else { out += String(n); pendingTens = nil }
                continue
            }
            if let t = pendingTens { out += String(t); pendingTens = nil }
            out += w
        }
        if let t = pendingTens { out += String(t) }
        return out
    }

    /// A word without punctuation, lowercased.
    static func plain(_ word: String) -> String { word.lowercased().filter { $0.isLetter || $0.isNumber } }

    private static let numbers: [String: Int] = {
        let small = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                     "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
        return Dictionary(uniqueKeysWithValues: small.enumerated().map { ($1, $0) }).merging(tens) { a, _ in a }
    }()

    // MARK: Cleanup

    private static let fillers: Set<String> = ["um", "umm", "uh", "uhm", "er", "erm", "ah", "hmm", "mm", "like", "so", "basically",
                                               "actually", "literally", "well", "okay", "ok"]
    private static let fillerPhrases: [[String]] = [["you", "know"], ["i", "mean"], ["kind", "of"], ["sort", "of"]]
    private static let cues: [[String]] = [["no"], ["wait"], ["sorry"], ["rather"], ["actually"], ["i", "mean"], ["scratch", "that"]]

    /// Removed words that are fillers, a repeat of their neighbours, or a false start ending in a correction cue.
    static func isCleanup(_ removed: Range<Int>, in pasted: [String]) -> Bool {
        let gone = pasted[removed].map(plain).filter { !$0.isEmpty }
        guard !gone.isEmpty else { return true }
        var rest = gone[...]
        while let first = rest.first {
            if fillers.contains(first) { rest = rest.dropFirst(); continue }
            guard let phrase = fillerPhrases.first(where: { rest.starts(with: $0) }) else { break }
            rest = rest.dropFirst(phrase.count)
        }
        if rest.isEmpty { return true }
        let n = removed.count
        let all = pasted.map(plain)
        if removed.lowerBound >= n, Array(all[(removed.lowerBound - n)..<removed.lowerBound]) == Array(all[removed]) { return true }
        if removed.upperBound + n <= all.count, Array(all[removed.upperBound..<(removed.upperBound + n)]) == Array(all[removed]) { return true }
        return cues.contains { cue in gone.count > cue.count && Array(gone.suffix(cue.count)) == cue }
    }

    // MARK: Misheard

    /// The part of `after` that sounds like `before`: all of it, or a prefix or suffix with the rest added on. Nil if none does.
    static func misheardSplit(_ before: [String], _ after: [String]) -> Range<Int>? {
        guard before.count <= maxMisheardWords else { return nil }
        // "he" to "she" or "a" to "the" can share a key, but changing them is usually a change of mind.
        if before.allSatisfy({ functionWords.contains(plain($0)) }), after.allSatisfy({ functionWords.contains(plain($0)) }) { return nil }
        let heard = phoneticKey(before.joined())
        var candidates = [0..<after.count]
        for k in 1..<max(after.count, 1) { candidates += [0..<k, k..<after.count] }
        let scored = candidates.filter { $0.count <= maxMisheardWords }
            .map { ($0, similarity(heard, phoneticKey(after[$0].joined()))) }
        // Prefer the whole run; a split must clear the bar on its own and beat the whole by a margin.
        guard let whole = scored.first else { return nil }
        if whole.1 >= soundsAlike { return whole.0 }
        guard let best = scored.dropFirst().max(by: { $0.1 < $1.1 }), best.1 >= soundsAlike, best.1 >= whole.1 + 0.2 else { return nil }
        return best.0
    }

    private static let functionWords: Set<String> = [
        "i", "me", "my", "you", "your", "we", "us", "our", "he", "him", "his", "she", "her", "they", "them", "their", "there",
        "it", "its", "itd", "itll", "this", "that", "thats", "these", "those", "is", "was", "are", "were", "be", "been", "am",
        "a", "an", "the", "and", "or", "but", "so", "to", "of", "in", "on", "at", "for", "with", "do", "does", "did", "have",
        "has", "had", "will", "would", "can", "could", "should", "im", "youre", "were", "theyre", "ill", "id", "ive", "not",
    ]

    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a.count <= 1 || b.count <= 1 { return a == b ? 1 : 0 }
        return 1 - Double(wordEditDistance(a.map(String.init), b.map(String.init))) / Double(max(a.count, b.count))
    }

    /// A consonant skeleton, joined across word breaks so "pie torch" and "PyTorch" share one key.
    /// Voiced and unvoiced pairs share a letter and vowels count only at the start.
    static func phoneticKey(_ text: String) -> String {
        let s = Array(text.lowercased().filter(\.isLetter))
        var out: [Character] = []
        var i = 0
        func emit(_ c: Character) { if out.last != c { out.append(c) } }
        while i < s.count {
            let c = s[i], next: Character? = i + 1 < s.count ? s[i + 1] : nil
            switch c {
            case "a", "e", "i", "o", "u", "y": if out.isEmpty { emit("A") }
            case "b", "p":
                if c == "p", next == "h" { emit("F"); i += 1 } else { emit("P") }
            case "c":
                if next == "h" { emit("X"); i += 1 } else if let n = next, "eiy".contains(n) { emit("S") } else { emit("K") }
            case "d", "t":
                if c == "t", next == "h" { emit("0"); i += 1 } else { emit("T") }
            case "f", "v": emit("F")
            case "g":
                if next == "h" { i += 1 } else if let n = next, "eiy".contains(n) { emit("J") } else { emit("K") }
            case "j": emit("J")
            case "k", "q":
                if c == "k", next == "n", out.isEmpty { break } else { emit("K") }
            case "l": emit("L")
            case "m": emit("M")
            case "n": emit("N")
            case "r": emit("R")
            case "s", "z":
                if c == "s", next == "h" { emit("X"); i += 1 } else { emit("S") }
            case "x": emit("K"); emit("S")
            default: break  // h, w
            }
            i += 1
        }
        return String(out)
    }
}
