//
//  UpdateService.swift
//  mankai
//
//  Created by Travis XU on 20/7/2025.
//

import Foundation

@MainActor final class UpdateService: ObservableObject {
    struct UpdateProgress: Equatable {
        var completed: Int
        let total: Int

        var fractionCompleted: Double {
            guard total > 0 else { return 0 }
            return Double(completed) / Double(total)
        }
    }

    private struct Persistence {
        let libraryItem: LibraryModel
        let manga: MangaModel?
    }

    /// The shared singleton instance of UpdateService.
    static let shared = UpdateService()

    private init() { Logger.updateService.debug("Initializing UpdateService") }

    /// The timestamp of the last update check.
    var lastUpdateTime: Date? {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "UpdateService.lastUpdateTime") as? Date
    }

    /// The current update progress, or `nil` when no update is running.
    @Published private(set) var progress: UpdateProgress?

    private var updateTask: Task<Void, Error>?

    /// Triggers the update process to check for new manga chapters.
    /// - Throws: An error if the update process fails.
    func update() async throws {
        let task: Task<Void, Error>
        let wasAlreadyRunning: Bool
        if let current = updateTask {
            task = current
            wasAlreadyRunning = true
        } else {
            progress = UpdateProgress(completed: 0, total: 0)
            let newTask = Task {
                defer {
                    self.progress = nil
                    self.updateTask = nil
                }
                try await self.internalUpdate()
            }
            updateTask = newTask
            task = newTask
            wasAlreadyRunning = false
        }

        if wasAlreadyRunning {
            Logger.updateService.debug("Update already in progress, skipping")
            return
        }

        Logger.updateService.debug("Starting update process")

        do { try await task.value } catch is CancellationError {
            Logger.updateService.debug("Update cancelled")
            throw CancellationError()
        } catch {
            Logger.updateService.error("Update failed", error: error)
            if case .online = Reach().connectionStatus() {
                let message = String(localized: "failedToUpdateLibraryFormat")
                NotificationService.shared.showError(
                    String(format: message, error.localizedDescription))
            }
            throw error
        }
    }

    private func internalUpdate() async throws {
        // Check if sync is needed (only if the sync engine is active)
        if SyncService.shared.engine?.active == true {
            if let lastSyncTime = SyncService.shared.lastSyncTime {
                // Check if last sync was more than 1 minute ago
                let timeInterval = Date().timeIntervalSince(lastSyncTime)
                if timeInterval > 60 {  // 1 minute in seconds
                    Logger.updateService.info("Syncing before update (last sync: \(lastSyncTime))")
                    do { try await SyncService.shared.sync(wait: true, showError: false) } catch {
                        Logger.updateService.error("Sync failed before update", error: error)
                        throw MankaiErrorCode.updateSyncFailed.makeError(underlyingError: error)
                    }
                }
            } else {
                // No sync has been performed yet
                Logger.updateService.info("Syncing before update (first sync)")
                do { try await SyncService.shared.sync(wait: true, showError: false) } catch {
                    Logger.updateService.error("Initial sync failed", error: error)
                    throw MankaiErrorCode.updateSyncFailed.makeError(underlyingError: error)
                }
            }
        }

        // Get all library mangas
        let libraryItems = LibraryService.shared.getAll()
        progress = UpdateProgress(completed: 0, total: libraryItems.count)
        Logger.updateService.debug(
            "Found \(libraryItems.count) library mangas to check for updates")

        // Group library items by pluginId
        var libraryItemsByPlugin: [String: [LibraryModel]] = [:]
        for libraryItem in libraryItems {
            if libraryItemsByPlugin[libraryItem.pluginId] == nil {
                libraryItemsByPlugin[libraryItem.pluginId] = []
            }
            libraryItemsByPlugin[libraryItem.pluginId]!.append(libraryItem)
        }

        // Process each plugin's library mangas
        var updatedLibraryItemCount = 0
        var updatedMangaCount = 0

        for (pluginId, pluginLibraryItems) in libraryItemsByPlugin {
            Logger.updateService.debug(
                "Checking updates for plugin: \(pluginId) (\(pluginLibraryItems.count) mangas)")
            // Get the plugin
            guard let plugin = PluginService.shared.getPlugin(pluginId) else {
                Logger.updateService.warning("Plugin not found: \(pluginId)")
                await advanceProgress(by: pluginLibraryItems.count)
                continue  // Skip if plugin doesn't exist
            }

            guard plugin.canUpdate else {
                Logger.updateService.debug("Skipping plugin without update support: \(pluginId)")
                await advanceProgress(by: pluginLibraryItems.count)
                continue
            }

            let mangaIds = pluginLibraryItems.map { $0.mangaId }

            let cachedMangas = MangaSnapshotService.shared.get(
                mangaIds: mangaIds, pluginId: pluginId)

            var hydrationIds: [String] = []
            var updateRequests: [MangaUpdateRequest] = []
            let usesCustomUpdates = plugin.supports(.mangaUpdates)
            for libraryItem in pluginLibraryItems {
                let latestChapter = libraryItem.latestChapter
                if let latestChapter {
                    updateRequests.append(
                        MangaUpdateRequest(id: libraryItem.mangaId, latestChapter: latestChapter))
                }

                if (usesCustomUpdates && cachedMangas[libraryItem.mangaId] == nil)
                    || latestChapter == nil
                {
                    hydrationIds.append(libraryItem.mangaId)
                }
            }

            var unresolvedHydrationIds = Set(hydrationIds)
            var pluginHadError = false
            var completedMangaIds: Set<String> = []
            let libraryItemsByMangaId = Dictionary(
                uniqueKeysWithValues: pluginLibraryItems.map { ($0.mangaId, $0) })

            // Let the update result provide the manga snapshot whenever possible.
            if !updateRequests.isEmpty {
                var results: [Manga] = []
                do { results = try await plugin.getMangaUpdates(updateRequests) } catch {
                    pluginHadError = true
                    Logger.updateService.error(
                        "Failed to check manga updates for plugin \(pluginId)", error: error)
                }

                let requestIds = Set(updateRequests.map(\.id))
                let completedBeforeRequest = completedMangaIds.count
                var persistenceBatch: [Persistence] = []
                for result in results {
                    guard requestIds.contains(result.id) else {
                        Logger.updateService.warning(
                            "Ignoring manga update result for unexpected ID \(result.id) from plugin \(pluginId)"
                        )
                        continue
                    }

                    guard result.updates != nil else {
                        Logger.updateService.warning(
                            "Ignoring manga update result without an updates flag for \(result.id) from plugin \(pluginId)"
                        )
                        completedMangaIds.insert(result.id)
                        continue
                    }

                    var manga = cachedMangas[result.id] ?? result
                    if let title = result.title { manga.title = title }
                    if let cover = result.cover { manga.cover = cover }
                    if let status = result.status { manga.status = status }
                    if let latestChapter = result.latestChapter {
                        manga.latestChapter = latestChapter
                    }
                    if let meta = result.meta { manga.meta = meta }
                    manga.updates = nil
                    unresolvedHydrationIds.remove(result.id)

                    guard var libraryItem = libraryItemsByMangaId[result.id] else { continue }
                    let hasUpdate = result.updates == true
                    if hasUpdate {
                        if let latestChapter = result.latestChapter {
                            libraryItem.latestChapter = latestChapter
                        }
                        libraryItem.datetime = Date()
                        libraryItem.updates = true
                        Logger.updateService.info(
                            "Plugin reported an update for manga: \(result.id) (Plugin: \(pluginId))"
                        )
                    }

                    persistenceBatch.append(
                        makePersistence(
                            manga: manga, mangaId: result.id, libraryItem: libraryItem,
                            pluginId: pluginId))
                    if hasUpdate { updatedLibraryItemCount += 1 }
                    completedMangaIds.insert(result.id)
                }

                updatedMangaCount += try await persist(persistenceBatch)
                await advanceProgress(by: completedMangaIds.count - completedBeforeRequest)
            }

            // Hydrate only manga that the update response did not resolve.
            if !unresolvedHydrationIds.isEmpty, plugin.supports(.batchMangas) {
                var mangas: [Manga] = []
                do { mangas = try await plugin.getMangas(Array(unresolvedHydrationIds)) } catch {
                    pluginHadError = true
                    Logger.updateService.error(
                        "Failed to hydrate manga snapshots in a batch for plugin \(pluginId)",
                        error: error)
                }

                let completedBeforeRequest = completedMangaIds.count
                var persistenceBatch: [Persistence] = []
                for manga in mangas where unresolvedHydrationIds.contains(manga.id) {
                    guard let libraryItem = libraryItemsByMangaId[manga.id] else { continue }
                    persistenceBatch.append(
                        makePersistence(
                            manga: manga, mangaId: manga.id, libraryItem: libraryItem,
                            pluginId: pluginId))
                    unresolvedHydrationIds.remove(manga.id)
                    completedMangaIds.insert(manga.id)
                }

                updatedMangaCount += try await persist(persistenceBatch)
                await advanceProgress(by: completedMangaIds.count - completedBeforeRequest)
            }

            if !unresolvedHydrationIds.isEmpty, plugin.supports(.mangaDetails) {
                for mangaId in hydrationIds where unresolvedHydrationIds.contains(mangaId) {
                    let manga: Manga
                    do { manga = try await plugin.getDetailedManga(mangaId).toManga() } catch {
                        pluginHadError = true
                        Logger.updateService.error(
                            "Failed to hydrate manga snapshot \(mangaId) for plugin \(pluginId)",
                            error: error)
                        if completedMangaIds.insert(mangaId).inserted { await advanceProgress() }
                        continue
                    }

                    guard let libraryItem = libraryItemsByMangaId[mangaId] else { continue }
                    let persistence = makePersistence(
                        manga: manga, mangaId: mangaId, libraryItem: libraryItem, pluginId: pluginId
                    )
                    updatedMangaCount += try await persist([persistence])
                    unresolvedHydrationIds.remove(mangaId)
                    if completedMangaIds.insert(mangaId).inserted { await advanceProgress() }
                }
            }

            if !unresolvedHydrationIds.isEmpty {
                Logger.updateService.warning(
                    "Could not hydrate \(unresolvedHydrationIds.count) manga snapshots for plugin \(pluginId)"
                )
            }

            await advanceProgress(by: pluginLibraryItems.count - completedMangaIds.count)

            if pluginHadError, case .online = Reach().connectionStatus() {
                let message = String(localized: "failedToCheckUpdatesForPluginFormat")
                NotificationService.shared.showWarning(String(format: message, pluginId))
            }
        }

        if updatedLibraryItemCount > 0 || updatedMangaCount > 0 {
            Logger.updateService.info(
                "Live updated \(updatedLibraryItemCount) library items and \(updatedMangaCount) mangas"
            )

            if updatedLibraryItemCount > 0, SyncService.shared.engine?.active == true {
                do { try await SyncService.shared.sync() } catch {
                    Logger.updateService.error("Sync failed after update", error: error)
                }
            }
        } else {
            Logger.updateService.debug("No updates found")
        }

        // Update last update time
        UserDefaults.standard.set(Date(), forKey: "UpdateService.lastUpdateTime")

        objectWillChange.send()
        Logger.updateService.debug("Update process completed")
    }

    private func makePersistence(
        manga: Manga, mangaId: String, libraryItem: LibraryModel, pluginId: String
    ) -> Persistence {
        var libraryItem = libraryItem
        if libraryItem.latestChapter == nil, let latestChapter = manga.latestChapter {
            libraryItem.latestChapter = latestChapter
            libraryItem.datetime = Date()
        }
        var mangaModel: MangaModel?
        do {
            mangaModel = try MangaSnapshotService.shared.makeSnapshot(
                for: manga, pluginId: pluginId)
        } catch {
            Logger.updateService.warning(
                "Failed to encode manga snapshot \(mangaId) from plugin \(pluginId): \(error.localizedDescription)"
            )
        }

        return Persistence(libraryItem: libraryItem, manga: mangaModel)
    }

    /// Persists all results produced by one plugin request in one transaction and UI event.
    private func persist(_ batch: [Persistence]) async throws -> Int {
        guard !batch.isEmpty else { return 0 }

        let mangas = batch.compactMap(\.manga)
        _ = try await LibraryService.shared.batchSave(
            libraryItems: batch.map(\.libraryItem), mangas: mangas)
        return mangas.count
    }

    private func advanceProgress(by count: Int = 1) async {
        guard count > 0 else { return }
        guard var progress else { return }
        progress.completed = min(progress.completed + count, progress.total)
        self.progress = progress
    }
}
