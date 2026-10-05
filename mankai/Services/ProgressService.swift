//
//  ProgressService.swift
//  mankai
//
//  Created by Travis XU on 17/7/2025.
//

import Combine
import Foundation
import GRDB

@MainActor final class ProgressService: ObservableObject {
    enum Change {
        case upserted([ProgressModel])
        case deleted([(mangaId: String, pluginId: String)])
    }

    static let shared = ProgressService()
    private let changeSubject = PassthroughSubject<Change, Never>()
    var changes: AnyPublisher<Change, Never> { changeSubject.eraseToAnyPublisher() }

    private init() { Logger.progressService.debug("Initializing ProgressService") }

    func get(mangaId: String, pluginId: String) -> ProgressModel? {
        do {
            return try DbService.shared.appDb?
                .read { db in
                    try ProgressModel.fetchOne(db, key: ["mangaId": mangaId, "pluginId": pluginId])
                }
        } catch {
            Logger.progressService.error("Failed to get reading progress", error: error)
            return nil
        }
    }

    func get(ids: [(mangaId: String, pluginId: String)]) -> [ProgressModel] {
        do {
            let keys = ids.map { ["mangaId": $0.mangaId, "pluginId": $0.pluginId] }
            return try DbService.shared.appDb?.read { try ProgressModel.fetchAll($0, keys: keys) }
                ?? []
        } catch {
            Logger.progressService.error("Failed to get reading progress", error: error)
            return []
        }
    }

    /// Saves and queues a local edit, then lets LibraryService clear the update badge.
    func save(progress: ProgressModel, manga: MangaModel? = nil) async throws -> Bool {
        let result = try await update(progress: progress, manga: manga, queueSync: true)
        if var libraryItem = LibraryService.shared.get(
            mangaId: progress.mangaId, pluginId: progress.pluginId), libraryItem.updates
        {
            libraryItem.updates = false
            libraryItem.datetime = Date()
            _ = try await LibraryService.shared.save(libraryItem: libraryItem)
        }
        return result
    }

    /// Updates local data only when newer, without queueing sync.
    func batchUpdateLocal(progressEntries: [ProgressModel], mangas: [MangaModel]? = nil)
        async throws -> Bool
    { try await batchUpdate(progressEntries: progressEntries, mangas: mangas, queueSync: false) }

    private func update(progress: ProgressModel, manga: MangaModel?, queueSync: Bool) async throws
        -> Bool
    {
        try await batchUpdate(
            progressEntries: [progress], mangas: manga.map { [$0] }, queueSync: queueSync)
    }

    private func batchUpdate(
        progressEntries: [ProgressModel], mangas: [MangaModel]?, queueSync: Bool
    ) async throws -> Bool {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.historyFailedToUpdateHistoryRecord.makeError()
        }
        if let mangas {
            for manga in mangas { _ = try? await MangaSnapshotService.shared.update(manga) }
        }

        let updated = try await appDb.write { db in
            var updated: [ProgressModel] = []
            for var progress in progressEntries {
                if !queueSync {
                    let mutation = SyncMutation(progress: progress)
                    guard try SyncService.shouldApply(mutation, in: db) else { continue }
                    if let current = try ProgressModel.fetchOne(
                        db, key: ["mangaId": progress.mangaId, "pluginId": progress.pluginId]),
                        !current.shouldSync
                            || !mutation.wins(over: SyncMutation.milliseconds(current.datetime))
                    {
                        continue
                    }
                }
                if queueSync { progress = try SyncService.enqueue(progress, in: db) }
                try progress.upsert(db)
                updated.append(progress)
            }
            return updated
        }

        if !updated.isEmpty { publish(.upserted(updated)) }
        if queueSync { SyncService.shared.scheduleSync() }
        return !updated.isEmpty
    }

    /// Deletes local data only, without queueing sync, after checking the sync timestamp.
    func deleteLocal(mangaId: String, pluginId: String, datetime: Date) async throws -> Bool {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.historyFailedToUpdateHistoryRecord.makeError()
        }
        let mutation = SyncMutation(
            entry: .progress(key: .init(sourceId: pluginId, mangaId: mangaId), payload: nil),
            action: .delete, date: datetime)
        let deleted = try await appDb.write { db in
            guard try SyncService.shouldApply(mutation, in: db) else { return false }
            let key = ["mangaId": mangaId, "pluginId": pluginId]
            if let current = try ProgressModel.fetchOne(db, key: key),
                !current.shouldSync
                    || !mutation.wins(over: SyncMutation.milliseconds(current.datetime))
            {
                return false
            }
            return try ProgressModel.deleteOne(db, key: key)
        }
        if deleted { publish(.deleted([(mangaId: mangaId, pluginId: pluginId)])) }
        return deleted
    }

    func getAll(limit: Int? = nil, offset: Int = 0, shouldSync: Bool? = nil) -> [ProgressModel] {
        do {
            return try DbService.shared.appDb?
                .read { db in
                    var request = ProgressModel.order(Column("datetime").desc)
                    if let limit { request = request.limit(limit, offset: offset) }
                    if let shouldSync {
                        request = request.filter(Column("shouldSync") == shouldSync)
                    }
                    return try request.fetchAll(db)
                } ?? []
        } catch {
            Logger.progressService.error("Failed to get reading progress", error: error)
            return []
        }
    }

    /// Clears progress and queues a clear marker for sync.
    func clear() async throws { try await clear(through: nil, queueSync: true) }

    /// Clears covered local progress only, without queueing sync.
    func clearLocal(through date: Date) async throws {
        try await clear(through: date, queueSync: false)
    }

    private func clear(through date: Date?, queueSync: Bool) async throws {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.historyFailedToUpdateHistoryRecord.makeError()
        }
        let deleted = try await appDb.write { db in
            let mutation: SyncMutation
            if queueSync {
                mutation = try SyncService.enqueueClear(in: db)
            } else {
                guard let date else { return [ProgressModel]() }
                mutation = SyncMutation(
                    entry: .progress(key: nil, payload: nil), action: .clear, date: date)
                guard try SyncService.shouldApply(mutation, in: db) else {
                    return [ProgressModel]()
                }
            }

            var request = ProgressModel.all()
            if !queueSync {
                request = request.filter(
                    Column("shouldSync") == true && Column("datetime") <= mutation.date)
            }
            let deleted = try request.fetchAll(db)
            try request.deleteAll(db)
            try SyncService.discardProgressMutations(through: mutation.datetime, in: db)
            return deleted
        }

        if !deleted.isEmpty {
            publish(.deleted(deleted.map { (mangaId: $0.mangaId, pluginId: $0.pluginId) }))
        }
        if queueSync { SyncService.shared.scheduleSync() }
    }

    private func publish(_ change: Change) {
        changeSubject.send(change)
        objectWillChange.send()
    }
}
