//
//  MangaSnapshotService.swift
//  mankai
//
//  Created by Travis XU on 10/9/2026.
//

import Combine
import Foundation
import GRDB

/// Manages the locally persisted snapshot of manga metadata.
@MainActor final class MangaSnapshotService: ObservableObject {
    nonisolated struct Upsert {
        let manga: Manga
        let pluginId: String
    }

    enum Change {
        case upserted([Upsert])
        case deleted(mangaId: String, pluginId: String)
    }

    static let shared = MangaSnapshotService()

    private let changeSubject = PassthroughSubject<Change, Never>()

    /// Publishes snapshot changes after their database transaction commits.
    var changes: AnyPublisher<Change, Never> { changeSubject.eraseToAnyPublisher() }

    private init() { Logger.mangaSnapshotService.debug("Initializing MangaSnapshotService") }

    /// Returns a decoded manga snapshot, or `nil` when it is unavailable or invalid.
    func get(mangaId: String, pluginId: String, in db: Database? = nil) -> Manga? {
        get(mangaIds: [mangaId], pluginId: pluginId, in: db)[mangaId]
    }

    /// Returns all valid decoded snapshots for the requested manga IDs.
    func get(mangaIds: [String], pluginId: String, in db: Database? = nil) -> [String: Manga] {
        guard !mangaIds.isEmpty else { return [:] }

        do {
            let snapshots: [MangaModel]
            if let db {
                snapshots = try fetch(mangaIds: mangaIds, pluginId: pluginId, in: db)
            } else {
                snapshots =
                    try DbService.shared.appDb?
                    .read { db in try self.fetch(mangaIds: mangaIds, pluginId: pluginId, in: db) }
                    ?? []
            }

            var mangas: [String: Manga] = [:]
            for snapshot in snapshots { mangas[snapshot.mangaId] = snapshot.info }
            return mangas
        } catch {
            Logger.mangaSnapshotService.error(
                "Failed to get manga snapshots from plugin \(pluginId)", error: error)
            return [:]
        }
    }

    /// Wraps manga metadata for local persistence.
    func makeSnapshot(for manga: Manga, pluginId: String) -> MangaModel {
        MangaModel(mangaId: manga.id, pluginId: pluginId, info: manga)
    }

    /// Inserts or replaces a snapshot in its own database transaction.
    @discardableResult func upsert(_ snapshot: MangaModel) async throws -> Upsert? {
        try await batchUpsert([snapshot]).first
    }

    /// Inserts or replaces multiple snapshots in their own database transaction.
    @discardableResult func batchUpsert(_ snapshots: [MangaModel]) async throws -> [Upsert] {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.libraryFailedToUpdateSavedManga.makeError()
        }

        let upserts = try await appDb.write { db -> [Upsert] in
            var upserts: [Upsert] = []
            upserts.reserveCapacity(snapshots.count)

            for snapshot in snapshots {
                try snapshot.upsert(db)
                upserts.append(Upsert(manga: snapshot.info, pluginId: snapshot.pluginId))
            }

            return upserts
        }

        if !upserts.isEmpty { publish(.upserted(upserts)) }

        return upserts
    }

    /// Updates an existing snapshot in its own database transaction.
    @discardableResult func update(_ snapshot: MangaModel) async throws -> Upsert? {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.libraryFailedToUpdateSavedManga.makeError()
        }

        let upsert = try await appDb.write { db in
            try snapshot.update(db)
            return Upsert(manga: snapshot.info, pluginId: snapshot.pluginId)
        }

        publish(.upserted([upsert]))
        return upsert
    }

    /// Deletes a snapshot in its own database transaction.
    @discardableResult func delete(mangaId: String, pluginId: String) async throws -> Bool {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.libraryFailedToDeleteSavedManga.makeError()
        }

        let deleted = try await appDb.write { db in
            try MangaModel.filter(Column("mangaId") == mangaId && Column("pluginId") == pluginId)
                .deleteAll(db) > 0
        }

        if deleted { publish(.deleted(mangaId: mangaId, pluginId: pluginId)) }
        return deleted
    }

    private func fetch(mangaIds: [String], pluginId: String, in db: Database) throws -> [MangaModel]
    {
        try MangaModel.filter(
            mangaIds.contains(Column("mangaId")) && Column("pluginId") == pluginId
        )
        .asRequest(of: Row.self).fetchAll(db)
        .compactMap { row in
            do { return try MangaModel(row: row) } catch {
                let mangaId: String = row["mangaId"]
                Logger.mangaSnapshotService.error(
                    "Failed to decode manga snapshot \(mangaId) from plugin \(pluginId)",
                    error: error)
                return nil
            }
        }
    }

    private func publish(_ change: Change) {
        changeSubject.send(change)
        objectWillChange.send()
    }
}
