import Foundation
import GlideCore
import Store

/// Keeps this Mac's history in step with the other devices on the same Ghenti account.
/// Push sends records changed here; pull applies changes from elsewhere. Everything is sealed before it leaves.
@MainActor
public final class SyncEngine {
    /// What this Mac knows about the server, kept beside history.
    struct State: Codable {
        var cursor: Int64 = 0
        var revisions: [UUID: Int] = [:]
        var dirty: Set<UUID> = []
        var deleted: Set<UUID> = []
        var audioSent: Set<UUID> = []
    }

    public enum Outcome: Equatable, Sendable {
        case synced(pushed: Int, pulled: Int)
        /// The account started fresh on another device; the vault has to be unlocked again for the new key.
        case needsNewKey(Int)
    }

    private let store: Store
    private let audio: AudioStore?
    private let api: GlideAPI
    private let crypto: SyncCrypto
    private let stateURL: URL
    private var state: State
    private var running = false

    public init(store: Store, audio: AudioStore?, api: GlideAPI, crypto: SyncCrypto, stateURL: URL) {
        self.store = store
        self.audio = audio
        self.api = api
        self.crypto = crypto
        self.stateURL = stateURL
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State()
        if state.revisions.isEmpty && state.cursor == 0 {
            // First sync from this Mac: everything already here goes up.
            state.dirty = Set(store.records.map(\.id))
        }
    }

    public func noteChanges(_ changed: [UUID], deleted: [UUID]) {
        state.dirty.formUnion(changed)
        state.deleted.formUnion(deleted)
        state.dirty.subtract(deleted)
        save()
    }

    /// Push, then pull. Calls while one is running are folded into it.
    @discardableResult
    public func sync() async throws -> Outcome {
        guard !running else { return .synced(pushed: 0, pulled: 0) }
        running = true
        defer { running = false }
        let account = try await api.account()
        if account.keyKid > crypto.kid { return .needsNewKey(account.keyKid) }
        let pushed = try await push()
        let pulled = try await pull()
        return .synced(pushed: pushed, pulled: pulled)
    }

    /// Turning sync off with "Delete from Ghenti".
    public func deleteEverything() async throws {
        try await api.deleteAllSynced()
        state = State()
        try? FileManager.default.removeItem(at: stateURL)
    }

    private func push() async throws -> Int {
        var pushed = 0
        for id in state.deleted {
            try await api.delete(id)
            state.deleted.remove(id)
            state.revisions[id] = nil
            save()
        }
        for id in state.dirty {
            guard let record = store.records.first(where: { $0.id == id }) else {
                state.dirty.remove(id)
                continue
            }
            try await upload(record)
            pushed += 1
            state.dirty.remove(id)
            save()
        }
        return pushed
    }

    private func upload(_ record: DictationRecord) async throws {
        let sealed = try crypto.seal(try JSONEncoder().encode(record), .record, id: record.id)
        do {
            let stored = try await api.put(record.id, kid: crypto.kid, sealed: sealed, baseRevision: state.revisions[record.id] ?? 0)
            state.revisions[record.id] = stored.revision
        } catch GlideAPI.APIError.status(404, _) where (state.revisions[record.id] ?? 0) > 0 {
            // Gone from the server (deleted everywhere from another device); a change made here brings it back.
            state.revisions[record.id] = try await api.put(record.id, kid: crypto.kid, sealed: sealed, baseRevision: 0).revision
        } catch GlideAPI.APIError.conflict(let current) {
            // Both sides changed it. The copy changed last wins; history edits carry their own newer time.
            if let theirs = try? open(current), (theirs.modified ?? .distantPast) > (record.modified ?? .distantPast) {
                store.applyRemote(theirs)
                state.revisions[record.id] = current.revision
            } else {
                let stored = try await api.put(record.id, kid: crypto.kid, sealed: sealed, baseRevision: current.revision)
                state.revisions[record.id] = stored.revision
            }
        }
        if let audio, !state.audioSent.contains(record.id), let opus = audio.load(record.id) {
            try await api.putAudio(record.id, sealed: try crypto.seal(opus, .audio, id: record.id))
            state.audioSent.insert(record.id)
        }
    }

    private func pull() async throws -> Int {
        var pulled = 0
        var cursor: Int64? = state.cursor
        while let after = cursor {
            let page = try await api.records(after: after, limit: 200)
            for item in page.items where state.revisions[item.id] != item.revision {
                if item.deleted {
                    store.removeRemote([item.id])
                    audio?.remove(item.id)
                    state.revisions[item.id] = nil
                    state.dirty.remove(item.id)
                } else if !state.dirty.contains(item.id), let record = try? open(item) {
                    // Records sealed under an older key generation can't be opened with this one and are left on the server.
                    store.applyRemote(record)
                    state.revisions[item.id] = item.revision
                    if item.hasAudio, let audio, !audio.has(item.id), let sealed = try? await api.audio(item.id),
                        let opus = try? crypto.open(sealed, .audio, id: item.id, kid: item.kid)
                    {
                        try? audio.save(opus, for: item.id)
                        state.audioSent.insert(item.id)
                    }
                }
                pulled += 1
            }
            if let last = page.items.last { state.cursor = last.seq }
            save()
            cursor = page.next
        }
        return pulled
    }

    private func open(_ item: GlideAPI.Record) throws -> DictationRecord {
        guard let sealed = item.sealed else { throw SyncCrypto.CryptoError.badEnvelope }
        return try JSONDecoder().decode(DictationRecord.self, from: crypto.open(sealed, .record, id: item.id, kid: item.kid))
    }

    private func save() {
        try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
}

/// Shares dictations for training: each one sealed to Ghenti's training key, which only Ghenti's training job can open.
public struct TrainingShare: Sendable {
    let api: GlideAPI
    /// Glide's vault key, which keys the training id.
    let appKey: Data

    public init(api: GlideAPI, appKey: Data) {
        self.api = api
        self.appKey = appKey
    }

    /// Anonymizes and seals a record with its recording. Sharing the same record again replaces the earlier copy,
    /// so a later correction updates what was shared.
    public func share(_ record: DictationRecord, opus: Data?) async throws {
        let key = try await api.trainingKey()
        let id = TrainingItem.id(for: record.id, appKey: appKey)
        let item = try TrainingCrypto.seal(try TrainingItem(anonymizing: record).framed(audio: opus), id: id, publicKeyPEM: key.publicKeyPem)
        try await api.putTrainingItem(id, keyVersion: key.version, item: item)
    }

    /// Takes back a record's item, as Not a Correction does.
    public func unshare(_ record: UUID) async throws { try await api.deleteTrainingItem(TrainingItem.id(for: record, appKey: appKey)) }

    /// Off deletes everything this person shared.
    @discardableResult
    public func setConsent(_ enabled: Bool) async throws -> GlideAPI.Consent { try await api.setTrainingConsent(enabled) }
}
