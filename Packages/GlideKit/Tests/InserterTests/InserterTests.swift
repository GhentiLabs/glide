import AppKit
import Testing
@testable import Inserter

@MainActor @Suite struct InserterTests {
    @Test func slowReaderGetsTheDictationNotTheOldClipboard() async {
        let board = NSPasteboard(name: .init("glide.test.\(UUID())"))
        board.clearContents()
        board.setString("user's clipboard", forType: .string)
        var got: String?
        let read = await Inserter.paste("dictated text", on: board) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                got = board.string(forType: .string)
            }
        }
        #expect(read)
        #expect(got == "dictated text")
        #expect(board.string(forType: .string) == "user's clipboard")
        board.releaseGlobally()
    }

    @Test func appThatReadsTwiceGetsTheDictationBothTimes() async {
        let board = NSPasteboard(name: .init("glide.test.\(UUID())"))
        board.clearContents()
        board.setString("user's clipboard", forType: .string)
        var reads: [String?] = []
        _ = await Inserter.paste("dictated text", on: board) {
            Task { @MainActor in
                reads.append(board.string(forType: .string))
                try? await Task.sleep(for: .milliseconds(150))
                reads.append(board.string(forType: .string))
            }
        }
        #expect(reads == ["dictated text", "dictated text"])
        #expect(board.string(forType: .string) == "user's clipboard")
        board.releaseGlobally()
    }

    @Test func unreadPasteTimesOutAndRestores() async {
        let board = NSPasteboard(name: .init("glide.test.\(UUID())"))
        board.clearContents()
        board.setString("user's clipboard", forType: .string)
        let read = await Inserter.paste("dictated text", on: board) {}
        #expect(!read)
        #expect(board.string(forType: .string) == "user's clipboard")
        board.releaseGlobally()
    }
}
