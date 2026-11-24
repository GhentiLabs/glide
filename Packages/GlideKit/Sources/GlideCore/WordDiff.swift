import Foundation

/// Word-level edit distance (substitutions, insertions, deletions).
public func wordEditDistance(_ a: [String], _ b: [String]) -> Int {
    var row = Array(0...b.count)
    for (i, word) in a.enumerated() {
        var diagonal = row[0]
        row[0] = i + 1
        for j in b.indices {
            let above = row[j + 1]
            row[j + 1] = word == b[j] ? diagonal : 1 + min(diagonal, above, row[j])
            diagonal = above
        }
    }
    return row[b.count]
}

/// Lowercased words with punctuation stripped, for scoring.
public func normalizedWords(_ text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
        .filter { !$0.isEmpty }
}
