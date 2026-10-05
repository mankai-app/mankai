//
//  HttpEngine.swift
//  mankai
//
//  Created by Travis XU on 4/8/2025.
//

import Foundation
import ReerCodable

final class HttpEngine: SyncEngine {
    static let shared = HttpEngine()

    @Encodable fileprivate struct SyncRequest {
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
                Logger.httpEngine.error("Sync response failed results, cursor, or data validation")
                throw MankaiErrorCode.syncHttpInvalidResponse.makeError()
            }

            for (result, mutation) in zip(results, mutations) {
                guard result.operationId == mutation.operationId else {
                    Logger.httpEngine.error("Sync response operation ID does not match the request")
                    throw MankaiErrorCode.syncHttpInvalidResponse.makeError()
                }
                switch result.status { case .applied:
                    guard result.revision != nil else {
                        Logger.httpEngine.error("Applied sync result is missing its revision")
                        throw MankaiErrorCode.syncHttpInvalidResponse.makeError()
                    }
                    case .ignored:
                        guard result.revision != nil,
                            result.current != nil || mutation.action == .clear
                        else {
                            Logger.httpEngine.error("Ignored sync result is missing conflict state")
                            throw MankaiErrorCode.syncHttpInvalidResponse.makeError()
                        }
                    case .invalid: break
                }
            }
        }
    }

    private let authManager: AuthManager

    override private init() {
        Logger.httpEngine.debug("Initializing HttpEngine")
        authManager = AuthManager(id: "HttpEngine")
        super.init()
        authManager.postSave = { [weak self] in self?.objectWillChange.send() }
        authManager.postLogin = { Task { try? await SyncService.shared.onEngineChange() } }
    }

    override var id: String { "HttpEngine" }
    override var name: String { String(localized: "httpEngine") }
    override var active: Bool { authManager.loggedIn }
    var username: String? { authManager.username }

    var serverUrl: String? {
        get { authManager.serverUrl }
        set {
            let url = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard url != authManager.serverUrl else { return }
            Logger.httpEngine.debug("HTTP sync server changed; resetting authentication")
            logout()
            authManager.serverUrl = url
        }
    }

    private var cursorKey: String { "\(id).cursor.\(serverUrl ?? "")\n\(username ?? "")" }

    func login(username: String, password: String) async throws {
        SyncService.shared.cancelSync()
        try await authManager.login(username: username, password: password)
    }

    func logout() {
        SyncService.shared.cancelSync()
        authManager.logout()
    }

    override func onSelected() async throws {
        Logger.httpEngine.debug("Resetting HTTP sync cursor")
        UserDefaults.standard.removeObject(forKey: cursorKey)
    }

    override func sync() async throws {
        guard active else {
            Logger.httpEngine.warning("Cannot start HTTP sync without authentication")
            throw MankaiErrorCode.authMissingCredentialsOrServerUrl.makeError()
        }
        let cursorKey = cursorKey
        let defaults = UserDefaults.standard
        var cursor = defaults.string(forKey: cursorKey)

        Logger.httpEngine.debug("Starting HTTP sync (bootstrap: \(cursor == nil))")
        let uploadBatchLimit = 500
        var mutations = try await SyncService.shared.uploadMutations(
            bootstrap: cursor == nil, limit: uploadBatchLimit)
        var recoveredCursor = false
        var requestCount = 0

        while true {
            try Task.checkCancellation()
            let body = try JSONEncoder().encode(SyncRequest(cursor: cursor, mutations: mutations))
            requestCount += 1
            Logger.httpEngine.debug(
                "Sending sync request \(requestCount): \(mutations.count) mutations, bootstrap: \(cursor == nil)"
            )
            let data: Data
            do { (data, _) = try await authManager.post(path: "/sync", body: body) } catch {
                let status =
                    (error as NSError).userInfo[MankaiErrorUserInfoKey.httpStatusCode] as? Int
                guard status == 400, cursor != nil, !recoveredCursor else { throw error }

                Logger.httpEngine.warning("Sync cursor rejected; retrying with bootstrap")
                defaults.removeObject(forKey: cursorKey)
                cursor = nil
                mutations = try await SyncService.shared.uploadMutations(
                    bootstrap: true, limit: uploadBatchLimit)
                recoveredCursor = true
                continue
            }

            try Task.checkCancellation()
            Logger.httpEngine.debug("Received sync response \(requestCount); validating")
            let page = try JSONDecoder().decode(SyncResponse.self, from: data)
            try page.validate(mutations: mutations, cursor: cursor)

            let appliedCount = page.results.filter { $0.status == .applied }.count
            let ignoredCount = page.results.filter { $0.status == .ignored }.count
            let invalidCount = page.results.filter { $0.status == .invalid }.count
            let incoming = page.incoming
            Logger.httpEngine.debug(
                "Sync results: \(appliedCount) applied, \(ignoredCount) ignored, \(invalidCount) invalid"
            )
            Logger.httpEngine.debug(
                "Applying \(incoming.count) incoming changes (hasMore: \(page.hasMore))")
            try await apply(incoming)
            try Task.checkCancellation()
            try await SyncService.shared.acknowledge(mutations)
            try Task.checkCancellation()

            // Services have committed every change. A failed page replays from the old cursor.
            defaults.set(page.nextCursor, forKey: cursorKey)
            cursor = page.nextCursor
            Logger.httpEngine.debug("Sync response \(requestCount) committed; cursor saved")
            if invalidCount > 0 {
                Logger.httpEngine.warning("Server rejected \(invalidCount) invalid sync mutations")
            }

            if page.hasMore {
                mutations = []
            } else {
                mutations = try await SyncService.shared.uploadMutations(
                    bootstrap: false, limit: uploadBatchLimit)
                if mutations.isEmpty { break }
            }
        }
        Logger.httpEngine.info("HTTP sync completed after \(requestCount) requests")
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
                Logger.httpEngine.debug("Applying plugin \(change.action.rawValue)")
                if change.action == .delete {
                    try PluginService.shared.deletePlugin(key.sourceId, datetime: change.date)
                } else if let payload {
                    try await PluginService.shared.updatePlugin(
                        url: payload.url, sourceId: key.sourceId, datetime: change.date)
                }

                case .library(let key, let payload):
                    if change.action == .delete {
                        Logger.httpEngine.debug("Applying library deletion")
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
                        Logger.httpEngine.debug("Applying progress clear")
                        try await ProgressService.shared.clearLocal(through: change.date)
                    } else if let key {
                        if change.action == .delete {
                            Logger.httpEngine.debug("Applying progress deletion")
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
            Logger.httpEngine.debug("Applying library update batch: \(libraryItems.count) items")
            let updated = try await LibraryService.shared.batchUpdateLocal(
                libraryItems: libraryItems)
            Logger.httpEngine.debug("Library update batch finished (changed: \(updated))")
        }
        if !progressEntries.isEmpty {
            try Task.checkCancellation()
            Logger.httpEngine.debug(
                "Applying progress update batch: \(progressEntries.count) items")
            let updated = try await ProgressService.shared.batchUpdateLocal(
                progressEntries: progressEntries)
            Logger.httpEngine.debug("Progress update batch finished (changed: \(updated))")
        }
    }
}
