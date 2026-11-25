import GlideCore
import Testing
@testable import Refiner

@Suite struct RefinerTests {
    let common: (String) -> Bool = { ["the", "send", "and", "can"].contains($0) }

    @Test func emptyFieldKeepsTextAsIs() {
        #expect(Refiner.join("Send it.", after: nil, isCommonWord: common) == "Send it.")
        #expect(Refiner.join("Send it.", after: "", isCommonWord: common) == "Send it.")
    }

    @Test func midSentenceAddsSpaceAndLowercasesCommonWords() {
        #expect(Refiner.join("The report.", after: "Please check", isCommonWord: common) == " the report.")
        #expect(Refiner.join("Priya said so.", after: "and", isCommonWord: common) == " Priya said so.")
        #expect(Refiner.join("I think so.", after: "well", isCommonWord: common) == " I think so.")
        #expect(Refiner.join("NASA can.", after: "well", isCommonWord: common) == " NASA can.")
    }

    @Test func afterSentenceKeepsCapitalAndRespectsExistingSpace() {
        #expect(Refiner.join("The end.", after: "Done. ", isCommonWord: common) == "The end.")
        #expect(Refiner.join("The end.", after: "Done.", isCommonWord: common) == " The end.")
        #expect(Refiner.join("Can we?", after: "(", isCommonWord: common) == "Can we?")
        #expect(Refiner.join(", and more", after: "apples", isCommonWord: common) == ", and more")
    }
}
