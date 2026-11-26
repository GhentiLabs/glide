import CryptoKit
import Foundation
import GlideCore
import Store
import Testing
@testable import Ghenti

/// Two Macs on one account, sharing a fake server.
@MainActor @Suite struct SyncEngineTests {
    struct Mac {
        let store: Store
        let audio: AudioStore
        let engine: SyncEngine
    }

    let server = FakeGhenti()
    let key = Data(repeating: 4, count: 32)

    func mac(kid: Int = 1) throws -> Mac {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-sync-\(UUID())")
        let store = Store(directory: dir)
        let audio = AudioStore(directory: dir.appendingPathComponent("Audio"), key: SymmetricKey(size: .bits256))
        let api = GlideAPI(base: URL(string: "https://glide.ghenti.com/v1")!, http: server, bearer: { "token" })
        let engine = SyncEngine(store: store, audio: audio, api: api, crypto: try SyncCrypto(appKey: key, kid: kid, sub: "user-1"),
                                stateURL: dir.appendingPathComponent("sync.json"))
        store.onRecordsChange = { engine.noteChanges($0, deleted: $1) }
        return Mac(store: store, audio: audio, engine: engine)
    }

    @Test func recordsEditsAndAudioReachTheOtherMacSealed() async throws {
        let a = try mac(), b = try mac()
        let record = DictationRecord(app: "com.apple.mail", rawTranscript: "see you thursday", refinedText: "See you Thursday.")
        a.store.add(record)
        try a.audio.save(Data("opus bytes".utf8), for: record.id)
        #expect(try await a.engine.sync() == .synced(pushed: 1, pulled: 0))

        // The server holds only sealed bytes.
        let everything = server.bodies.reduce(Data(), +)
        #expect(everything.range(of: Data("Thursday".utf8)) == nil && everything.range(of: Data("opus bytes".utf8)) == nil)

        try await b.engine.sync()
        #expect(b.store.records.map(\.refinedText) == ["See you Thursday."])
        #expect(b.audio.load(record.id) == Data("opus bytes".utf8))

        b.store.setFinal(record.id, text: "See you Friday.", source: .history, diff: [], labellerVersion: 1)
        try await b.engine.sync()
        try await a.engine.sync()
        #expect(a.store.records.first?.finalText == "See you Friday.")
    }

    @Test func theLaterEditWinsAConflict() async throws {
        let a = try mac(), b = try mac()
        let record = DictationRecord(app: nil, rawTranscript: "x", refinedText: "Draft.")
        a.store.add(record)
        try await a.engine.sync()
        try await b.engine.sync()

        a.store.setFinal(record.id, text: "From A.", source: .history, diff: [], labellerVersion: 1)
        try await Task.sleep(for: .milliseconds(20))
        b.store.setFinal(record.id, text: "From B, later.", source: .history, diff: [], labellerVersion: 1)
        try await a.engine.sync()
        try await b.engine.sync()  // conflicts with A's revision; B's copy is newer, so it goes up
        try await a.engine.sync()
        #expect(a.store.records.first?.finalText == "From B, later.")
        #expect(b.store.records.first?.finalText == "From B, later.")
    }

    @Test func deletionsAndClearedHistorySpread() async throws {
        let a = try mac(), b = try mac()
        a.store.add(DictationRecord(app: nil, rawTranscript: "one", refinedText: "One."))
        a.store.add(DictationRecord(app: nil, rawTranscript: "two", refinedText: "Two."))
        try await a.engine.sync()
        try await b.engine.sync()
        #expect(b.store.records.count == 2)
        a.store.clearHistory()
        try await a.engine.sync()
        try await b.engine.sync()
        #expect(b.store.records.isEmpty)
    }

    @Test func historyAlreadyOnAMacGoesUpOnItsFirstSync() async throws {
        let a = try mac()
        a.store.onRecordsChange = nil  // as if added before sync was turned on
        a.store.add(DictationRecord(app: nil, rawTranscript: "old", refinedText: "Old."))
        let fresh = SyncEngine(store: a.store, audio: a.audio,
                               api: GlideAPI(base: URL(string: "https://glide.ghenti.com/v1")!, http: server, bearer: { "t" }),
                               crypto: try SyncCrypto(appKey: key, kid: 1, sub: "user-1"),
                               stateURL: FileManager.default.temporaryDirectory.appendingPathComponent("glide-sync-\(UUID()).json"))
        #expect(try await fresh.sync() == .synced(pushed: 1, pulled: 0))
    }

    @Test func aNewerKeyGenerationElsewhereAsksForTheVault() async throws {
        let a = try mac(kid: 1)
        server.keyKid = 2
        #expect(try await a.engine.sync() == .needsNewKey(2))
    }
}
