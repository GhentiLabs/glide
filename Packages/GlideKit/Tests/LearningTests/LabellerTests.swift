import GlideCore
import Testing
@testable import Learning

@Suite struct LabellerTests {
    private func kinds(_ pasted: String, _ final: String, raw: String? = nil) -> [EditSpan.Kind] {
        Labeller.label(raw: raw ?? pasted, pasted: pasted, final: final).map(\.kind)
    }

    @Test func untouchedTextHasNoSpans() {
        #expect(kinds("Ship it on Friday.", "Ship it on Friday.").isEmpty)
        #expect(kinds("Ship it on   Friday.", "Ship it on Friday.").isEmpty)  // spacing alone is not an edit
    }

    @Test func soundAlikeReplacementsAreMisheard() {
        #expect(kinds("Deploy it to cooper netties today.", "Deploy it to Kubernetes today.") == [.misheard])
        #expect(kinds("Train it with pie torch tonight.", "Train it with PyTorch tonight.") == [.misheard])
        #expect(kinds("Book a flight to see addle.", "Book a flight to Seattle.") == [.misheard])
        #expect(kinds("The whether is nice.", "The weather is nice.") == [.misheard])
    }

    @Test func differentWordsAreRewrites() {
        #expect(kinds("Send it Monday.", "Send it Tuesday.") == [.rewrite])
        #expect(kinds("The big dog barked.", "The large dog barked.") == [.rewrite])
        #expect(kinds("Tell me how this works and why it fails.", "Explain it.") == [.rewrite])
    }

    @Test func formattingIsFoldedAway() {
        #expect(kinds("We need to set up two servers.", "We need to setup 2 servers.") == [.formatting])
        #expect(kinds("Is it done.", "Is it done?") == [.formatting])
        #expect(kinds("about twenty two percent", "about 22%") == [.formatting])
        #expect(kinds("push it to git hub", "push it to GitHub") == [.formatting])
    }

    @Test func removedFillersRepeatsAndFalseStartsAreCleanup() {
        #expect(kinds("So um I think we should go.", "I think we should go.") == [.cleanup])
        #expect(kinds("I think the the plan works.", "I think the plan works.") == [.cleanup])
        #expect(kinds("Meet on Tuesday, no wait, Wednesday.", "Meet on Wednesday.") == [.cleanup])
        // Dropped content is not cleanup; the period that moved is formatting.
        #expect(kinds("Meet on Tuesday at the office.", "Meet on Tuesday.") == [.formatting, .rewrite])
    }

    @Test func newWordsAreAdditions() {
        #expect(kinds("Call me", "Call me tomorrow, please.") == [.addition])
        // The period moved, so that part is formatting, not a mishearing.
        #expect(kinds("Call me.", "Call me tomorrow, please.") == [.formatting, .addition])
    }

    @Test func aFixWithExtraWordsSplitsIntoMisheardAndAddition() {
        let spans = Labeller.label(raw: "deploy to cooper netties", pasted: "deploy to cooper netties", final: "deploy to Kubernetes in staging")
        #expect(spans.map(\.kind) == [.misheard, .addition])
        #expect(spans.map(\.after) == ["Kubernetes", "in staging"])
        #expect(spans[0].finalWords == 2..<3 && spans[1].finalWords == 3..<5)
    }

    @Test func puttingBackWhatTheRulesChangedIsRestored() {
        #expect(kinds("I think it works.", "I think, like, it works.", raw: "I think, like, it works.") == [.formatting, .restored])
        // Without a change between raw and pasted, retyping a word is an addition.
        #expect(kinds("the cat sat", "the cat sat the", raw: "the cat sat") == [.addition])
    }

    @Test func spansKeepTheirPositionsInBothTexts() {
        let spans = Labeller.label(raw: "a b c d", pasted: "a b c d", final: "a x c d e")
        #expect(spans.map(\.pastedWords) == [1..<2, 4..<4])
        #expect(spans.map(\.finalWords) == [1..<2, 4..<5])
    }

    @Test func punctuationAtTheEdgeDoesNotDragNeighboursIntoAMatch() {
        // A trailing period would otherwise make "my folder." look like one replacement with "a folder".
        #expect(kinds("I moved it into my folder. Then", "I moved it into a folder that then") == [.rewrite, .formatting, .addition, .formatting])
        #expect(kinds("ask where the meeting is.", "ask where the meeting with the team was?") == [.addition, .rewrite])
        #expect(kinds("Honestly, like the plan works.", "Honestly the plan works.") == [.formatting, .cleanup])
    }

    @Test func vocabularyTakesOnlyUnusualMisheardWords() {
        // "kubernetes" is in this spell checker, as it is on some Macs; the capital the user typed still marks it as a name.
        let common: (String) -> Bool = { ["weather", "the", "check", "log", "on", "staging", "kubernetes"].contains($0) }
        let spans = Labeller.label(
            raw: "", pasted: "Check the whether log on cooper netties.", final: "Check the weather log on Kubernetes.")
        let words = Labeller.vocabulary(from: spans, isCommonWord: common)
        #expect(words.map(\.word) == ["Kubernetes"])
        #expect(words.first?.heardAs == "cooper netties")
    }

    @Test func phoneticKeysJoinAcrossWordBreaks() {
        #expect(Labeller.phoneticKey("pie torch") == Labeller.phoneticKey("PyTorch"))
        #expect(Labeller.phoneticKey("male formed") == Labeller.phoneticKey("malformed"))
        #expect(Labeller.phoneticKey("Monday") != Labeller.phoneticKey("Tuesday"))
    }
}
