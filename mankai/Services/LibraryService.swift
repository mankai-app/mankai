//
//  LibraryService.swift
//  mankai
//
//  Created by Travis XU on 17/7/2025.
//

import Combine
import Foundation
import GRDB

@MainActor final class LibraryService: ObservableObject {
    enum Change {
        case upserted(libraryItems: [LibraryModel], snapshots: [MangaSnapshotService.Upsert])
        case deleted(mangaId: String, pluginId: String)
    }

    static let shared = LibraryService()
    private let changeSubject = PassthroughSubject<Change, Never>()
    var changes: AnyPublisher<Change, Never> { changeSubject.eraseToAnyPublisher() }

    private init() { Logger.libraryService.debug("Initializing LibraryService") }

    func get(mangaId: String, pluginId: String) -> LibraryModel? {
        do {
            return try DbService.shared.appDb?
                .read { db in
                    try LibraryModel.fetchOne(db, key: ["mangaId": mangaId, "pluginId": pluginId])
                }
        } catch {
            Logger.libraryService.error("Failed to get library manga", error: error)
            return nil
        }
    }

    /// Saves a local edit and queues it for sync in the same transaction.
    func save(libraryItem: LibraryModel, manga: MangaModel? = nil) async throws -> Bool {
        try await update(libraryItem: libraryItem, manga: manga, queueSync: true)
    }

    func batchSave(libraryItems: [LibraryModel], mangas: [MangaModel]? = nil) async throws -> Bool {
        try await batchUpdate(libraryItems: libraryItems, mangas: mangas, queueSync: true)
    }

    /// Updates local data only when newer, without queueing sync.
    func batchUpdateLocal(libraryItems: [LibraryModel], mangas: [MangaModel]? = nil) async throws
        -> Bool
    { try await batchUpdate(libraryItems: libraryItems, mangas: mangas, queueSync: false) }

    private func update(libraryItem: LibraryModel, manga: MangaModel?, queueSync: Bool) async throws
        -> Bool
    {
        try await batchUpdate(
            libraryItems: [libraryItem], mangas: manga.map { [$0] }, queueSync: queueSync)
    }

    private func batchUpdate(libraryItems: [LibraryModel], mangas: [MangaModel]?, queueSync: Bool)
        async throws -> Bool
    {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.libraryFailedToUpdateSavedManga.makeError()
        }
        let snapshots: [MangaSnapshotService.Upsert]
        if let mangas {
            snapshots = try await MangaSnapshotService.shared.batchUpsert(mangas)
        } else {
            snapshots = []
        }
        let updated = try await appDb.write { db in
            var updated: [LibraryModel] = []
            for var libraryItem in libraryItems {
                if !queueSync {
                    guard let mutation = SyncMutation(library: libraryItem),
                        try SyncService.shouldApply(mutation, in: db)
                    else { continue }
                    if let current = try LibraryModel.fetchOne(
                        db, key: ["mangaId": libraryItem.mangaId, "pluginId": libraryItem.pluginId]),
                        !current.shouldSync
                            || !mutation.wins(over: SyncMutation.milliseconds(current.datetime))
                    {
                        continue
                    }
                }
                if queueSync { libraryItem = try SyncService.enqueue(libraryItem, in: db) }
                try libraryItem.upsert(db)
                updated.append(libraryItem)
            }
            return updated
        }

        if !updated.isEmpty { publish(.upserted(libraryItems: updated, snapshots: snapshots)) }
        if queueSync { SyncService.shared.scheduleSync() }
        return !updated.isEmpty
    }

    func remove(mangaId: String, pluginId: String) async throws -> Bool {
        try await delete(mangaId: mangaId, pluginId: pluginId, queueSync: true)
    }

    /// Deletes local data only, without queueing sync. A timestamp enables sync conflict checks.
    func deleteLocal(mangaId: String, pluginId: String, datetime: Date? = nil) async throws -> Bool
    { try await delete(mangaId: mangaId, pluginId: pluginId, queueSync: false, datetime: datetime) }

    private func delete(mangaId: String, pluginId: String, queueSync: Bool, datetime: Date? = nil)
        async throws -> Bool
    {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.libraryFailedToDeleteSavedManga.makeError()
        }
        let mutation = SyncMutation(
            entry: .library(key: .init(sourceId: pluginId, mangaId: mangaId), payload: nil),
            action: .delete, date: datetime ?? Date())
        let result = try await appDb.write { db -> Bool? in
            let key = ["mangaId": mangaId, "pluginId": pluginId]
            let current = try LibraryModel.fetchOne(db, key: key)
            if datetime != nil {
                guard try SyncService.shouldApply(mutation, in: db) else { return nil }
                if let current,
                    !current.shouldSync
                        || !mutation.wins(over: SyncMutation.milliseconds(current.datetime))
                {
                    return nil
                }
            }
            if queueSync, current?.shouldSync == true { try SyncService.enqueue(mutation, in: db) }
            return try LibraryModel.deleteOne(db, key: key)
        }

        guard let result else { return false }
        _ = try await MangaSnapshotService.shared.delete(mangaId: mangaId, pluginId: pluginId)
        publish(.deleted(mangaId: mangaId, pluginId: pluginId))
        if queueSync { SyncService.shared.scheduleSync() }
        return result
    }

    func getAll(shouldSync: Bool? = nil) -> [LibraryModel] {
        do {
            return try DbService.shared.appDb?
                .read { db in
                    var request = LibraryModel.order(Column("datetime").desc)
                    if let shouldSync {
                        request = request.filter(Column("shouldSync") == shouldSync)
                    }
                    return try request.fetchAll(db)
                } ?? []
        } catch {
            Logger.libraryService.error("Failed to get library mangas", error: error)
            return []
        }
    }

    private func publish(_ change: Change) {
        changeSubject.send(change)
        objectWillChange.send()
    }
}
