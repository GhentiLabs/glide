import Testing
@testable import GlideCore

@Suite struct WordDiffTests {
    @Test func distances() {
        #expect(wordEditDistance([], []) == 0)
        #expect(wordEditDistance([], ["a", "b"]) == 2)
        #expect(wordEditDistance(["a", "b"], []) == 2)
        #expect(wordEditDistance(["the", "cat", "sat"], ["the", "bat", "sat", "down"]) == 2)
    }

    @Test func normalizing() {
        #expect(normalizedWords("Hello, World! It's fine.") == ["hello", "world", "it's", "fine"])
    }
}
