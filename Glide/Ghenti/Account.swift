import Foundation
import Ghenti
import GlideCore
import Store
import os

/// The Ghenti account in Glide: sign-in, the vault key, sync across devices and sharing for training.
/// Nothing leaves the Mac until the person signs in and turns sync or sharing on.
@MainActor @Observable
final class Account {
    private(set) var user: GhentiUser?
    private(set) var hasKey = false
    /// What's happening right now, in words for the UI; nil when idle.
    private(set) var activity: String?
    private(set) var problem: String?
    private(set) var lastSync: Date?

    var syncEnabled: Bool { UserDefaults.standard.bool(forKey: "syncEnabled") }
    var sharesForTraining: Bool { UserDefaults.standard.bool(forKey: "shareForTraining") }

    @ObservationIgnored let session = GhentiSession(web: SystemWebAuthenticator())
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let audio: AudioStore
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    private let log = Logger(subsystem: "com.ghentilabs.glide", category: "ghenti")

    init(store: Store, audio: AudioStore) {
        self.store = store
        self.audio = audio
        Task { await load() }
    }

    private var api: GlideAPI {
        GlideAPI(base: session.config.api) { [session] in try await session.bearer() }
    }

    private func load() async {
        user = await session.user
        hasKey = await session.appKey != nil
        if syncEnabled { await startSync() }
    }

    // MARK: Sign-in

    func signIn() async {
        await run("Finish signing in in the Ghenti window.") {
            user = try await session.signIn()
            hasKey = await session.appKey != nil
            Telemetry.event("ghenti_signed_in")
        }
    }

    /// Unlocks the Ghenti vault for Glide's key, which sync needs.
    func unlock() async {
        await run("Unlock your vault in the Ghenti window.") {
            try await session.unlockKey()
            hasKey = true
            if syncEnabled { await startSync() }
        }
    }

    func signOut() async {
        stopSync()
        await session.signOut()
        UserDefaults.standard.set(false, forKey: "syncEnabled")
        UserDefaults.standard.set(false, forKey: "shareForTraining")
        user = nil
        hasKey = false
        lastSync = nil
    }

    // MARK: Sync

    /// On asks for the vault key if Glide doesn't have it yet. Off can also delete everything synced from Ghenti.
    func setSync(_ on: Bool, deleteFromGhenti: Bool = false) async {
        if on {
            UserDefaults.standard.set(true, forKey: "syncEnabled")
            if !hasKey { await unlock() }
            if hasKey { await startSync() } else { UserDefaults.standard.set(false, forKey: "syncEnabled") }
        } else {
            if deleteFromGhenti, let engine {
                await run("Deleting your synced dictations from Ghenti.") { try await engine.deleteEverything() }
            }
            UserDefaults.standard.set(false, forKey: "syncEnabled")
            stopSync()
        }
    }

    /// Called by the store for every change made on this Mac.
    func recordsChanged(_ changed: [UUID], deleted: [UUID]) {
        engine?.noteChanges(changed, deleted: deleted)
        guard engine != nil else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(3))  // one sync for a burst of edits
            if !Task.isCancelled { await syncNow() }
        }
    }

    func syncNow() async {
        guard let engine else { return }
        do {
            switch try await engine.sync() {
            case .synced:
                lastSync = .now
                problem = nil
            case .needsNewKey:
                // The account started fresh elsewhere; this key opens nothing new.
                hasKey = false
                problem = "Your Ghenti vault has a new key. Unlock it to keep syncing."
            }
        } catch GhentiError.signedOut {
            user = nil
            problem = "Sign in to Ghenti again to keep syncing."
        } catch {
            log.error("sync failed: \(error.localizedDescription, privacy: .public)")
            problem = "Couldn't sync. Glide will try again."
        }
    }

    private func startSync() async {
        guard let key = await session.appKey, let crypto = try? SyncCrypto(appKey: key.key, kid: key.kid, sub: key.sub) else { return }
        let engine = SyncEngine(store: store, audio: audio, api: api, crypto: crypto,
                                stateURL: Store.defaultDirectory.appendingPathComponent("sync-\(key.sub)-\(key.kid).json"))
        self.engine = engine
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
        await syncNow()
    }

    private func stopSync() {
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        engine = nil
    }

    // MARK: Training

    /// On shares each new dictation once its edits are in, and asks for the vault key first, which keys
    /// the anonymous training ids. Off deletes everything shared.
    func setSharing(_ on: Bool) async {
        if on && !hasKey { await unlock() }
        guard !on || hasKey else { return }
        await run(on ? nil : "Deleting what you shared.") {
            _ = try await api.setTrainingConsent(on)
            UserDefaults.standard.set(on, forKey: "shareForTraining")
        }
    }

    /// Shares a settled dictation, anonymized, with its recording, unless the person ruled it out.
    func share(_ id: UUID) {
        guard sharesForTraining, user != nil, let record = store.records.first(where: { $0.id == id }), record.excluded != true
        else { return }
        let opus = audio.load(id)
        Task {
            guard let share = await training() else { return }
            do { try await share.share(record, opus: opus) } catch {
                log.error("training share failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Not a Correction takes a shared dictation back.
    func unshare(_ id: UUID) {
        guard sharesForTraining, user != nil else { return }
        Task { try? await training()?.unshare(id) }
    }

    private func training() async -> TrainingShare? {
        guard let key = await session.appKey else { return nil }
        return TrainingShare(api: api, appKey: key.key)
    }

    // MARK: Helpers

    private func run(_ message: String?, _ work: () async throws -> Void) async {
        activity = message
        problem = nil
        defer { activity = nil }
        do {
            try await work()
        } catch GhentiError.cancelled {
            return
        } catch {
            log.error("ghenti: \(String(describing: error), privacy: .public)")
            problem = Self.describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case GhentiError.wrongAccount: "That vault belongs to a different Ghenti account."
        case GhentiError.signedOut: "Sign in to Ghenti again."
        case GhentiError.stateMismatch, GhentiError.badKey: "Ghenti sent back something Glide didn't expect. Try again."
        case is URLError: "Couldn't reach Ghenti. Check your connection."
        default: "Something went wrong with Ghenti. Try again."
        }
    }
}
