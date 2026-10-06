//
//  CooldownWrapper.swift
//  mankai
//
//  Created by Travis XU on 6/8/2026.
//

import Foundation

private actor CooldownScheduler {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let clock = ContinuousClock()
    private var nextExecutionTime: ContinuousClock.Instant?
    private var waiters: [Waiter] = []
    private var pendingWaiterId: UUID?
    private var wakeTask: Task<Void, Never>?

    func wait(milliseconds: Int) async throws -> Bool {
        try Task.checkCancellation()
        guard milliseconds > 0 else { return false }

        let now = clock.now
        if pendingWaiterId == nil, waiters.isEmpty, nextExecutionTime.map({ $0 <= now }) ?? true {
            nextExecutionTime = now.advanced(by: .milliseconds(milliseconds))
            return false
        }

        let id = UUID()

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(Waiter(id: id, continuation: continuation))
                    scheduleNextWaiter()
                }
            } onCancel: {
                Task { await self.cancelWaiter(id: id) }
            }

            try Task.checkCancellation()
            confirmWaiter(id: id, milliseconds: milliseconds)
            return true
        } catch {
            cancelWaiter(id: id)
            throw error
        }
    }

    private func scheduleNextWaiter(clearingWakeTask: Bool = false) {
        if clearingWakeTask { wakeTask = nil }

        guard pendingWaiterId == nil, !waiters.isEmpty else { return }

        let now = clock.now
        if let nextExecutionTime, nextExecutionTime > now {
            guard wakeTask == nil else { return }

            let clock = clock
            wakeTask = Task { [weak self] in
                do { try await clock.sleep(until: nextExecutionTime) } catch { return }
                await self?.scheduleNextWaiter(clearingWakeTask: true)
            }
            return
        }

        let waiter = waiters.removeFirst()
        pendingWaiterId = waiter.id
        waiter.continuation.resume()
    }

    private func confirmWaiter(id: UUID, milliseconds: Int) {
        guard pendingWaiterId == id else { return }

        pendingWaiterId = nil
        nextExecutionTime = clock.now.advanced(by: .milliseconds(milliseconds))
        scheduleNextWaiter()
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
            return
        }

        guard pendingWaiterId == id else { return }
        pendingWaiterId = nil
        scheduleNextWaiter()
    }
}

private actor AsyncSemaphore {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var availablePermits: Int
    private var waiters: [Waiter] = []

    init(permits: Int) { availablePermits = permits }

    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if availablePermits > 0 {
                    availablePermits -= 1
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

class CooldownWrapper: Plugin {
    private let plugin: Plugin
    private var configurablePlugin: any Configurable {
        guard let configurablePlugin = plugin as? any Configurable else {
            preconditionFailure("Configurable wrapper requires a configurable plugin")
        }
        return configurablePlugin
    }
    private let configuredCooldown: Cooldown
    private let pluginScheduler = CooldownScheduler()
    private let imageScheduler = CooldownScheduler()
    private let imageSemaphore: AsyncSemaphore?

    static func wrapping(_ plugin: Plugin) -> Plugin {
        guard let cooldown = plugin.cooldown else { return plugin }

        if let configurableEditablePlugin = plugin as? any Configurable & Editable {
            return ConfigurableEditableCooldownWrapper(
                plugin: configurableEditablePlugin, cooldown: cooldown)
        }

        if let editablePlugin = plugin as? any Editable {
            return EditableCooldownWrapper(plugin: editablePlugin, cooldown: cooldown)
        }

        if plugin is any Configurable {
            return ConfigurableCooldownWrapper(plugin: plugin, cooldown: cooldown)
        }

        return CooldownWrapper(plugin: plugin, cooldown: cooldown)
    }

    fileprivate init(plugin: Plugin, cooldown: Cooldown) {
        self.plugin = plugin
        configuredCooldown = cooldown

        if let concurrency = cooldown.getImageConcurrency, concurrency > 0 {
            imageSemaphore = AsyncSemaphore(permits: concurrency)
        } else {
            imageSemaphore = nil
        }

        super.init()
        Logger.cooldownWrapper.debug("Initialized CooldownWrapper for plugin: \(plugin.id)")

        if let milliseconds = cooldown.default, milliseconds > 0 {
            Logger.cooldownWrapper.debug(
                "Configured plugin cooldown of \(milliseconds)ms for plugin: \(plugin.id)")
        }
        if let milliseconds = cooldown.getImage, milliseconds > 0 {
            Logger.cooldownWrapper.debug(
                "Configured getImage cooldown of \(milliseconds)ms for plugin: \(plugin.id)")
        }
        if let concurrency = cooldown.getImageConcurrency, concurrency > 0 {
            Logger.cooldownWrapper.debug(
                "Configured getImage concurrency limit of \(concurrency) for plugin: \(plugin.id)")
        }
    }

    // MARK: - Metadata Delegation

    override var id: String { plugin.id }

    override var name: String? { plugin.name }

    override var version: String? { plugin.version }

    override var tags: [String] { plugin.tags }

    override var description: String? { plugin.description }

    override var authors: [String] { plugin.authors }

    override var repository: String? { plugin.repository }

    override var availableGenres: [Genre] { plugin.availableGenres }

    var configs: [Config] { configurablePlugin.configs }

    override var cooldown: Cooldown? { plugin.cooldown }

    override var capabilities: [PluginCapability] { plugin.capabilities }

    override var typeCapabilities: [PluginTypeCapability] { plugin.typeCapabilities }

    override func encodeURL() -> String { plugin.encodeURL() }

    // MARK: - Config Delegation

    var configValues: [ConfigValue] { configurablePlugin.configValues }

    func getConfig(_ key: String) -> Any { configurablePlugin.getConfig(key) }

    func setConfig(key: String, value: Any) throws {
        defer { objectWillChange.send() }
        try configurablePlugin.setConfig(key: key, value: value)
    }

    func resetConfigs() throws {
        defer { objectWillChange.send() }
        try configurablePlugin.resetConfigs()
    }

    // MARK: - Method Delegation

    override func savePlugin() throws { try plugin.savePlugin() }

    override func deletePlugin() throws { try plugin.deletePlugin() }

    private func wait(
        milliseconds: Int?, using scheduler: CooldownScheduler, before operation: String
    ) async throws {
        guard let milliseconds, milliseconds > 0 else { return }

        Logger.cooldownWrapper.debug(
            "Checking cooldown (\(milliseconds)ms) before \(operation) for plugin: \(plugin.id)")
        let didWait = try await scheduler.wait(milliseconds: milliseconds)

        if didWait {
            Logger.cooldownWrapper.debug(
                "Cooldown wait completed before \(operation) for plugin: \(plugin.id)")
        } else {
            Logger.cooldownWrapper.debug(
                "No cooldown wait needed before \(operation) for plugin: \(plugin.id)")
        }
    }

    override func isOnline() async throws -> Bool {
        try await wait(
            milliseconds: configuredCooldown.default, using: pluginScheduler, before: "isOnline")
        return try await plugin.isOnline()
    }

    override func getSuggestions(_ query: String) async throws -> [String] {
        try await wait(
            milliseconds: configuredCooldown.default, using: pluginScheduler,
            before: "getSuggestions")
        return try await plugin.getSuggestions(query)
    }

    override func search(_ query: String, page: UInt, genre: Genre, status: Status, isAuthor: Bool)
        async throws -> [Manga]
    {
        try await wait(
            milliseconds: configuredCooldown.default, using: pluginScheduler, before: "search")
        return try await plugin.search(
            query, page: page, genre: genre, status: status, isAuthor: isAuthor)
    }

    override func getList(page: UInt, genre: Genre, status: Status) async throws -> [Manga] {
        try await wait(
            milliseconds: configuredCooldown.default, using: pluginScheduler, before: "getList")
        return try await plugin.getList(page: page, genre: genre, status: status)
    }

    override func getMangas(_ ids: [String]) async throws -> [Manga] {
        try await wait(
            milliseconds: configuredCooldown.default, using: pluginScheduler, before: "getMangas")
        return try await plugin.getMangas(ids)
    }

    override func getMangaUpdates(_ mangas: [MangaUpdateRequest]) async throws -> [Manga] {
        try await wait(
            milliseconds: configuredCooldown.default, using: pluginScheduler,
            before: "getMangaUpdates")
        return try await plugin.getMangaUpdates(mangas)
    }

    override func getDetailedManga(_ id: String) async throws -> DetailedManga {
        try await wait(
            milliseconds: configuredCooldown.default, using: pluginScheduler,
            before: "getDetailedManga")
        return try await plugin.getDetailedManga(id)
    }

    override func getChapter(manga: DetailedManga, chapter: Chapter) async throws -> [String] {
        try await wait(
            milliseconds: configuredCooldown.default, using: pluginScheduler, before: "getChapter")
        return try await plugin.getChapter(manga: manga, chapter: chapter)
    }

    override func getImage(_ url: String) async throws -> Data {
        guard let imageSemaphore else {
            try await wait(
                milliseconds: configuredCooldown.getImage, using: imageScheduler, before: "getImage"
            )
            return try await plugin.getImage(url)
        }

        Logger.cooldownWrapper.debug(
            "Waiting for getImage concurrency permit for plugin: \(plugin.id)")
        try await imageSemaphore.acquire()
        Logger.cooldownWrapper.debug(
            "Acquired getImage concurrency permit for plugin: \(plugin.id)")

        do {
            try await wait(
                milliseconds: configuredCooldown.getImage, using: imageScheduler, before: "getImage"
            )
            let data = try await plugin.getImage(url)
            await imageSemaphore.release()
            Logger.cooldownWrapper.debug(
                "Released getImage concurrency permit for plugin: \(plugin.id)")
            return data
        } catch {
            await imageSemaphore.release()
            Logger.cooldownWrapper.debug(
                "Released getImage concurrency permit after failure for plugin: \(plugin.id)")
            throw error
        }
    }
}

private final class ConfigurableCooldownWrapper: CooldownWrapper, Configurable {}

private class EditableCooldownWrapper: CooldownWrapper, Editable {
    private let editablePlugin: any Editable

    init(plugin: any Editable, cooldown: Cooldown) {
        editablePlugin = plugin
        super.init(plugin: plugin, cooldown: cooldown)
    }

    func upsertManga(_ manga: EditableManga) async throws -> String {
        try await editablePlugin.upsertManga(manga)
    }

    func deleteManga(_ mangaId: String) async throws {
        try await editablePlugin.deleteManga(mangaId)
    }

    func upsertCover(mangaId: String, image: Data) async throws {
        try await editablePlugin.upsertCover(mangaId: mangaId, image: image)
    }

    func upsertChapterGroup(_ group: EditableChapterGroup) async throws {
        try await editablePlugin.upsertChapterGroup(group)
    }

    func deleteChapterGroup(id: String) async throws {
        try await editablePlugin.deleteChapterGroup(id: id)
    }

    func getChapters(groupId: String) async throws -> [Chapter] {
        try await editablePlugin.getChapters(groupId: groupId)
    }

    func upsertChapter(_ chapter: EditableChapter) async throws {
        try await editablePlugin.upsertChapter(chapter)
    }

    func deleteChapter(id: String) async throws { try await editablePlugin.deleteChapter(id: id) }

    func arrangeChapterOrder(ids: [String]) async throws {
        try await editablePlugin.arrangeChapterOrder(ids: ids)
    }

    func addImages(chapterId: String, images: [Data]) async throws {
        try await editablePlugin.addImages(chapterId: chapterId, images: images)
    }

    func deleteImages(ids: [String]) async throws {
        try await editablePlugin.deleteImages(ids: ids)
    }

    func arrangeImageOrder(ids: [String]) async throws {
        try await editablePlugin.arrangeImageOrder(ids: ids)
    }
}

private final class ConfigurableEditableCooldownWrapper: EditableCooldownWrapper, Configurable {}
