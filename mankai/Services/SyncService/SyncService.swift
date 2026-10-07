//
//  SyncService.swift
//  mankai
//
//  Created by Travis XU on 20/7/2025.
//

import Combine
import Foundation
import GRDB

@MainActor final class SyncService: ObservableObject {
    /// The shared singleton instance of SyncService.
    static let shared = SyncService()
    /// The list of available synchronization engines.
    static let engines: [SyncEngine] = [HttpEngine.shared, SupabaseEngine.shared]

    private init() {
        Logger.syncService.debug("Initializing SyncService")
        let defaults = UserDefaults.standard
        if let engineId = defaults.string(forKey: "SyncService.engineId") {
            _engine = SyncService.engines.first(where: { $0.id == engineId })
            subscribeToEngine()
            startPeriodicSync()
        }
    }

    private var _engine: SyncEngine?
    private var engineCancellable: AnyCancellable?
    private var syncTimer: Timer?
    private var syncTask: Task<Void, Error>?
    private var engineChangeTask: Task<Void, Never>?
    private let syncInterval: TimeInterval = 60 * 3  // 3 minutes

    /// A flag indicating if a synchronization process is currently in progress.
    @Published private(set) var isSyncing = false

    /// The currently active synchronization engine.
    var engine: SyncEngine? {
        get { _engine }
        set {
            guard _engine?.id != newValue?.id else { return }
            Logger.syncService.debug("Setting sync engine: \(newValue?.id ?? "nil")")
            engineChangeTask?.cancel()
            syncTask?.cancel()
            _engine = newValue

            let defaults = UserDefaults.standard
            defaults.setValue(newValue?.id, forKey: "SyncService.engineId")

            subscribeToEngine()

            if newValue != nil {
                startPeriodicSync(syncImmediately: false)
            } else {
                stopPeriodicSync()
            }

            objectWillChange.send()

            engineChangeTask = Task { try? await self.onEngineChange() }
        }
    }

    /// The timestamp of the last successful synchronization.
    var lastSyncTime: Date? {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "SyncService.lastSyncTime") as? Date
    }

    /// Handles changes when the sync engine is updated.
    /// - Throws: An error if the new engine cannot be initialized.
    func onEngineChange() async throws {
        try Task.checkCancellation()
        Logger.syncService.debug("Handling engine change")
        syncTask?.cancel()
        if let current = syncTask { try? await current.value }
        try Task.checkCancellation()
        guard let engine else { return }

        // Reset last sync time in UserDefaults
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "SyncService.lastSyncTime")

        try await engine.onSelected()
        try Task.checkCancellation()
        try await sync(wait: true)
        try Task.checkCancellation()
        try await UpdateService.shared.update()
    }

    private func subscribeToEngine() {
        engineCancellable?.cancel()
        engineCancellable = engine?.objectWillChange
            .sink { [weak self] _ in Task { @MainActor in self?.objectWillChange.send() } }
    }

    private func startPeriodicSync(syncImmediately: Bool = true) {
        stopPeriodicSync()

        guard engine != nil else { return }

        Logger.syncService.debug("Starting periodic sync")
        // Engine changes perform their initial sync after resetting the engine.
        if syncImmediately {
            Task {
                try? await sync()
                try? await UpdateService.shared.update()
            }
        }

        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) {
            [weak self] _ in Task { try? await self?.sync() }
        }
    }

    private func stopPeriodicSync() {
        Logger.syncService.debug("Stopping periodic sync")
        syncTimer?.invalidate()
        syncTimer = nil
    }

    isolated deinit {
        stopPeriodicSync()
        engineChangeTask?.cancel()
        engineCancellable?.cancel()
    }

    /// Triggers a synchronization process.
    /// - Parameter wait: If true, waits for an ongoing sync to complete before proceeding (or skipping).
    /// - Throws: An error if the synchronization fails.
    func sync(wait: Bool = false, showError: Bool = true, caller: String = #function) async throws {
        Logger.syncService.debug("Sync requested by \(caller)")
        let task: Task<Void, Error>
        let wasAlreadyRunning: Bool
        if let current = syncTask {
            task = current
            wasAlreadyRunning = true
        } else {
            isSyncing = true
            let newTask = Task {
                defer {
                    self.isSyncing = false
                    self.syncTask = nil
                }
                try await internalSync()
            }
            syncTask = newTask
            task = newTask
            wasAlreadyRunning = false
        }

        if wasAlreadyRunning {
            if !wait {
                Logger.syncService.debug("Sync already in progress, skipping")
                return
            }
            Logger.syncService.debug("Waiting for ongoing sync to complete")
        }

        do { try await task.value } catch {
            if error is CancellationError || task.isCancelled
                || (error as? URLError)?.code == .cancelled
            {
                Logger.syncService.debug("Sync cancelled")
                throw CancellationError()
            }
            Logger.syncService.error("Sync failed", error: error)

            if showError, engine?.active == true, case .online = Reach().connectionStatus() {
                let message = String(localized: "failedToSyncFormat")
                NotificationService.shared.showWarning(
                    String(format: message, error.localizedDescription))
            }

            throw error
        }

        if wasAlreadyRunning { Logger.syncService.debug("Ongoing sync completed, proceeding") }
    }

    private func internalSync() async throws {
        Logger.syncService.debug("Starting sync")
        try Task.checkCancellation()
        guard let engine = engine else {
            Logger.syncService.error("No sync engine available")
            throw MankaiErrorCode.syncNoEngine.makeError()
        }

        guard engine.active else {
            Logger.syncService.debug("Cannot sync: engine is inactive")
            throw MankaiErrorCode.syncEngineInactive.makeError()
        }

        Logger.syncService.debug("Running sync with engine: \(engine.id)")
        try await engine.sync()
        try Task.checkCancellation()

        // Update sync time
        UserDefaults.standard.set(Date(), forKey: "SyncService.lastSyncTime")

        objectWillChange.send()
        Logger.syncService.info("Sync completed with engine: \(engine.id)")
    }

    /// Called after a local transaction, network failures leave its mutations pending.
    func scheduleSync() {
        guard engine?.active == true else {
            Logger.syncService.debug("Skipping scheduled sync: engine is inactive")
            return
        }
        Logger.syncService.debug("Scheduling sync for local changes")
        Task { try? await sync(showError: false) }
    }

    func cancelSync() {
        if syncTask != nil { Logger.syncService.debug("Cancelling current sync") }
        syncTask?.cancel()
    }

    /// Bootstrap queues current data as upserts, ordinary uploads read only pending operations.
    func uploadMutations(bootstrap: Bool, limit: Int) async throws -> [SyncMutation] {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.syncHttpInvalidResponse.makeError()
        }

        if !bootstrap {
            let mutations = try await appDb.read { db in
                try SyncQueueModel.order(Column("datetime")).limit(limit).fetchAll(db)
                    .map(\.mutation)
            }
            Logger.syncService.debug("Loaded \(mutations.count) pending sync mutations")
            return mutations
        }

        Logger.syncService.debug("Preparing bootstrap sync mutations")
        let plugins =
            PluginService.shared.plugins.compactMap { SyncMutation(plugin: $0) }
            + BrowseService.shared.plugins.compactMap { SyncMutation(plugin: $0, browsable: true) }

        let mutations = try await appDb.write { db in
            var current = plugins.filter(\.isValid)
            current += try LibraryModel.filter(Column("shouldSync") == true).fetchAll(db)
                .compactMap { SyncMutation(library: $0) }.filter(\.isValid)
            current += try ProgressModel.filter(Column("shouldSync") == true).fetchAll(db)
                .map { SyncMutation(progress: $0) }.filter(\.isValid)

            return try current.compactMap { mutation in
                // A pending local edit already has the state and ID we must retry.
                if let queued = try SyncQueueModel.request(for: mutation).fetchOne(db) {
                    return queued.mutation.action == .upsert ? queued.mutation : nil
                }

                try SyncQueueModel(mutation).save(db)
                return mutation
            }
        }
        Logger.syncService.debug("Prepared \(mutations.count) bootstrap sync mutations")
        // Bootstrap queues every current item, including those left for later batches.
        return Array(mutations.prefix(limit))
    }

    /// Delete only the operations sent in this request, newer local edits have different IDs.
    func acknowledge(_ mutations: [SyncMutation]) async throws {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.syncHttpInvalidResponse.makeError()
        }
        let ids = mutations.compactMap(\.operationId)
        let deleted = try await appDb.write { db in
            try SyncQueueModel.filter(ids.contains(Column("operationId"))).deleteAll(db)
        }
        Logger.syncService.debug(
            "Acknowledged \(ids.count) sent operations, removed \(deleted) queue entries")
    }

    /// Services check pending edits inside the same transaction as their remote write.
    nonisolated static func shouldApply(_ mutation: SyncMutation, in db: Database) throws -> Bool {
        if let queued = try SyncQueueModel.request(for: mutation).fetchOne(db),
            !mutation.wins(over: queued.mutation)
        {
            Logger.syncService.debug(
                "Skipping incoming \(mutation.type.rawValue) \(mutation.action.rawValue): a pending local edit wins"
            )
            return false
        }
        if mutation.type == .progress, mutation.action != .clear,
            let clear = try SyncQueueModel.progressClear.fetchOne(db),
            mutation.datetime <= clear.datetime
        {
            Logger.syncService.debug("Skipping incoming progress covered by a pending clear")
            return false
        }
        return true
    }

    nonisolated static func discardProgressMutations(through datetime: Int64, in db: Database)
        throws
    {
        let deleted =
            try SyncQueueModel.filter(
                Column("type") == "progress" && Column("sourceId") != ""
                    && Column("datetime") <= datetime
            )
            .deleteAll(db)
        if deleted > 0 {
            Logger.syncService.debug(
                "Removed \(deleted) pending progress operations covered by clear")
        }
    }

    /// Keep a local row and its pending operation in one transaction.
    @discardableResult nonisolated static func enqueue(_ mutation: SyncMutation, in db: Database)
        throws -> SyncMutation
    {
        var mutation = mutation
        guard mutation.isValid else { throw MankaiErrorCode.syncHttpInvalidResponse.makeError() }

        if let queued = try SyncQueueModel.request(for: mutation).fetchOne(db) {
            if mutation.datetime <= queued.datetime, mutation.action == queued.mutation.action,
                mutation.entry == queued.mutation.entry
            {
                Logger.syncService.debug(
                    "Reusing pending \(mutation.type.rawValue) \(mutation.action.rawValue) operation"
                )
                return queued.mutation
            }
            mutation.datetime = max(mutation.datetime, queued.datetime + 1)
        }

        // Acknowledged operations leave the queue, so also check the current row's timestamp.
        switch mutation.entry { case .library(let key, _):
            if let current = try LibraryModel.fetchOne(
                db, key: ["mangaId": key.mangaId, "pluginId": key.sourceId])
            {
                mutation.datetime = max(
                    mutation.datetime, SyncMutation.milliseconds(current.datetime) + 1)
            }
            case .progress(let key?, _):
                if let current = try ProgressModel.fetchOne(
                    db, key: ["mangaId": key.mangaId, "pluginId": key.sourceId])
                {
                    mutation.datetime = max(
                        mutation.datetime, SyncMutation.milliseconds(current.datetime) + 1)
                }
                if let clear = try SyncQueueModel.progressClear.fetchOne(db) {
                    mutation.datetime = max(mutation.datetime, clear.datetime + 1)
                }
            default: break
        }

        Logger.syncService.debug(
            "Writing \(mutation.type.rawValue) \(mutation.action.rawValue) operation to sync queue")
        try SyncQueueModel(mutation).save(db)
        return mutation
    }

    nonisolated static func enqueue(_ library: LibraryModel, in db: Database) throws -> LibraryModel
    {
        var library = library
        guard library.shouldSync, let mutation = SyncMutation(library: library) else {
            return library
        }

        if let current = try LibraryModel.fetchOne(
            db, key: ["mangaId": library.mangaId, "pluginId": library.pluginId]),
            current.updates == library.updates, current.latestChapter == library.latestChapter,
            current.datetime >= library.datetime
        {
            Logger.syncService.debug("Skipping unchanged library sync state")
            library.datetime = current.datetime
            return library
        }

        library.datetime = try enqueue(mutation, in: db).date
        return library
    }

    nonisolated static func enqueue(_ progress: ProgressModel, in db: Database) throws
        -> ProgressModel
    {
        var progress = progress
        guard progress.shouldSync else { return progress }
        progress.datetime = try enqueue(SyncMutation(progress: progress), in: db).date
        return progress
    }

    nonisolated static func enqueuePlugin(
        id: String, url: String?, type: String, browsable: Bool = false, in db: Database
    ) throws {
        guard let url else { return }
        let key = SyncMutation.SourceKey(sourceId: id)
        let payload = SyncMutation.PluginPayload(url: url, type: type)
        let mutation = SyncMutation(
            entry: browsable
                ? .browsableplugin(key: key, payload: payload) : .plugin(key: key, payload: payload)
        )
        if let queued = try SyncQueueModel.request(for: mutation).fetchOne(db),
            queued.mutation.action == .upsert, queued.mutation.entry == mutation.entry
        {
            Logger.syncService.debug("Plugin sync state is already queued")
            return
        }
        try enqueue(mutation, in: db)
    }

    nonisolated static func enqueueClear(in db: Database) throws -> SyncMutation {
        var mutation = SyncMutation(entry: .progress(key: nil, payload: nil), action: .clear)
        // Cover all existing progress, including edits whose clock or queue advanced ahead of now.
        for progress in try ProgressModel.fetchAll(db) {
            mutation.datetime = max(mutation.datetime, SyncMutation.milliseconds(progress.datetime))
        }
        for queued in try SyncQueueModel.filter(Column("type") == "progress").fetchAll(db) {
            mutation.datetime = max(mutation.datetime, queued.datetime)
        }
        return try enqueue(mutation, in: db)
    }
}
