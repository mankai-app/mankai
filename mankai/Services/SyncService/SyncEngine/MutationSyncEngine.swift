//
//  MutationSyncEngine.swift
//  mankai
//
//  Created by Travis XU on 6/10/2026.
//

import Foundation
import ReerCodable

/// Shares mutation validation, pagination, conflict application, and queue acknowledgement across sync transports.
/// A cursor advances only after all local changes have committed.
class MutationSyncEngine: SyncEngine {
    @Encodable struct SyncRequest: Sendable {
        @CustomCoding<String?>(encode: { encoder, cursor in
            try encoder.set(cursor.map { AnyCodable($0) } ?? .null, forKey: "cursor")
        }) var cursor: String?
        var mutations: [SyncMutation]
    }

    private struct SyncResult: Decodable {
        enum Status: String, Decodable { case applied, ignored, invalid }
        var operationId: String?
        var status: Status
        var revision: String?
        var current: SyncMutation?
    }

    private struct SyncResponse: Decodable {
        var results: [SyncResult]
        var changes: [SyncMutation]
        var nextCursor: String
        var hasMore: Bool

        var incoming: [SyncMutation] { results.compactMap(\.current) + changes }

        func validate(mutations: [SyncMutation], cursor: String?) throws {
            guard results.count == mutations.count, !nextCursor.isEmpty,
                !hasMore || nextCursor != cursor, incoming.allSatisfy(\.isValid)
            else {
                Logger.syncEngine.error("Sync response failed results, cursor, or data validation")
                throw MankaiErrorCode.syncInvalidResponse.makeError()
            }

            for (result, mutation) in zip(results, mutations) {
                guard result.operationId == mutation.operationId else {
                    Logger.syncEngine.error("Sync response operation ID does not match the request")
                    throw MankaiErrorCode.syncInvalidResponse.makeError()
                }
                switch result.status { case .applied:
                    guard result.revision != nil else {
                        Logger.syncEngine.error("Applied sync result is missing its revision")
                        throw MankaiErrorCode.syncInvalidResponse.makeError()
                    }
                    case .ignored:
                        guard result.revision != nil,
                            result.current != nil || mutation.action == .clear
                        else {
                            Logger.syncEngine.error("Ignored sync result is missing conflict state")
                            throw MankaiErrorCode.syncInvalidResponse.makeError()
                        }
                    case .invalid: break
                }
            }
        }
    }

    func syncMutations(
        cursorKey: String, send: (SyncRequest) async throws -> Data,
        isInvalidCursor: (Error) -> Bool
    ) async throws {
        let defaults = UserDefaults.standard
        var cursor = defaults.string(forKey: cursorKey)

        Logger.syncEngine.debug("Starting mutation sync (bootstrap: \(cursor == nil))")
        let uploadBatchLimit = 500
        var mutations = try await SyncService.shared.uploadMutations(
            bootstrap: cursor == nil, limit: uploadBatchLimit)
        var recoveredCursor = false
        var requestCount = 0

        while true {
            try Task.checkCancellation()
            requestCount += 1
            Logger.syncEngine.debug(
                "Sending sync request \(requestCount): \(mutations.count) mutations, bootstrap: \(cursor == nil)"
            )
            let data: Data
            do { data = try await send(SyncRequest(cursor: cursor, mutations: mutations)) } catch {
                guard isInvalidCursor(error), cursor != nil, !recoveredCursor else { throw error }

                Logger.syncEngine.warning("Sync cursor rejected, retrying with bootstrap")
                defaults.removeObject(forKey: cursorKey)
                cursor = nil
                mutations = try await SyncService.shared.uploadMutations(
                    bootstrap: true, limit: uploadBatchLimit)
                recoveredCursor = true
                continue
            }

            try Task.checkCancellation()
            Logger.syncEngine.debug("Received sync response \(requestCount), validating")
            let page = try JSONDecoder().decode(SyncResponse.self, from: data)
            try page.validate(mutations: mutations, cursor: cursor)

            let appliedCount = page.results.filter { $0.status == .applied }.count
            let ignoredCount = page.results.filter { $0.status == .ignored }.count
            let invalidCount = page.results.filter { $0.status == .invalid }.count
            let incoming = page.incoming
            Logger.syncEngine.debug(
                "Sync results: \(appliedCount) applied, \(ignoredCount) ignored, \(invalidCount) invalid"
            )
            Logger.syncEngine.debug(
                "Applying \(incoming.count) incoming changes (hasMore: \(page.hasMore))")
            try await apply(incoming)
            try Task.checkCancellation()
            try await SyncService.shared.acknowledge(mutations)
            try Task.checkCancellation()

            // Services have committed every change. A failed page replays from the old cursor.
            defaults.set(page.nextCursor, forKey: cursorKey)
            cursor = page.nextCursor
            Logger.syncEngine.debug("Sync response \(requestCount) committed, cursor saved")
            if invalidCount > 0 {
                Logger.syncEngine.warning("Server rejected \(invalidCount) invalid sync mutations")
            }

            if page.hasMore {
                mutations = []
            } else {
                mutations = try await SyncService.shared.uploadMutations(
                    bootstrap: false, limit: uploadBatchLimit)
                if mutations.isEmpty { break }
            }
        }
        Logger.syncEngine.info("Mutation sync completed after \(requestCount) requests")
    }

    private func apply(_ changes: [SyncMutation]) async throws {
        var libraryItems: [LibraryModel] = []
        var progressEntries: [ProgressModel] = []

        for change in changes {
            try Task.checkCancellation()

            // Commit preceding upserts before a delete or clear changes their rows.
            if change.action != .upsert {
                try await applyUpdates(libraryItems: libraryItems, progressEntries: progressEntries)
                libraryItems.removeAll()
                progressEntries.removeAll()
            }

            switch change.entry { case .plugin(let key, let payload):
                Logger.syncEngine.debug("Applying plugin \(change.action.rawValue)")
                if change.action == .delete {
                    try PluginService.shared.deletePlugin(key.sourceId, datetime: change.date)
                } else if let payload {
                    try await PluginService.shared.updatePlugin(
                        url: payload.url, sourceId: key.sourceId, datetime: change.date)
                }

                case .library(let key, let payload):
                    if change.action == .delete {
                        Logger.syncEngine.debug("Applying library deletion")
                        _ = try await LibraryService.shared.deleteLocal(
                            mangaId: key.mangaId, pluginId: key.sourceId, datetime: change.date)
                    } else if let payload {
                        libraryItems.append(
                            LibraryModel(
                                mangaId: key.mangaId, pluginId: key.sourceId, datetime: change.date,
                                updates: payload.updates, latestChapter: payload.latestChapter))
                    }

                case .progress(let key, let payload):
                    if change.action == .clear {
                        Logger.syncEngine.debug("Applying progress clear")
                        try await ProgressService.shared.clearLocal(through: change.date)
                    } else if let key {
                        if change.action == .delete {
                            Logger.syncEngine.debug("Applying progress deletion")
                            _ = try await ProgressService.shared.deleteLocal(
                                mangaId: key.mangaId, pluginId: key.sourceId, datetime: change.date)
                        } else if let payload {
                            progressEntries.append(
                                ProgressModel(
                                    mangaId: key.mangaId, pluginId: key.sourceId,
                                    datetime: change.date, chapterId: payload.chapterId,
                                    chapterTitle: payload.chapterTitle, page: payload.page))
                        }
                    }
            }
        }

        try await applyUpdates(libraryItems: libraryItems, progressEntries: progressEntries)
    }

    private func applyUpdates(libraryItems: [LibraryModel], progressEntries: [ProgressModel])
        async throws
    {
        if !libraryItems.isEmpty {
            try Task.checkCancellation()
            Logger.syncEngine.debug("Applying library update batch: \(libraryItems.count) items")
            let updated = try await LibraryService.shared.batchUpdateLocal(
                libraryItems: libraryItems)
            Logger.syncEngine.debug("Library update batch finished (changed: \(updated))")
        }
        if !progressEntries.isEmpty {
            try Task.checkCancellation()
            Logger.syncEngine.debug(
                "Applying progress update batch: \(progressEntries.count) items")
            let updated = try await ProgressService.shared.batchUpdateLocal(
                progressEntries: progressEntries)
            Logger.syncEngine.debug("Progress update batch finished (changed: \(updated))")
        }
    }
}
