//
//  PluginService.swift
//  mankai
//
//  Created by Travis XU on 21/6/2025.
//

import Foundation
import GRDB

enum PluginAddConflictResolution: Equatable {
    case reject
    case overwrite
}

@MainActor final class PluginService: ObservableObject {
    /// The shared singleton instance of `PluginService`.
    static let shared = PluginService()

    private init() {
        Logger.pluginService.debug("Initializing PluginService")

        // Add built-in plugins
        _plugins[AppDirPlugin.shared.id] = AppDirPlugin.shared

        // Load JS plugins
        loadJsPlugins()

        // Load FS plugins
        loadFsPlugins()

        // Load HTTP plugins
        loadHttpPlugins()
    }

    private var _plugins: [String: Plugin] = [:]

    /// A list of all available plugins.
    var plugins: [Plugin] { return Array(_plugins.values) }

    /// Reconstruct and save a downloaded plugin without queueing it again.
    func updatePlugin(url: String, sourceId: String, datetime: Date) async throws {
        if _plugins[sourceId]?.syncURL == url { return }
        let mutation = SyncMutation(
            entry: .plugin(key: .init(sourceId: sourceId), payload: .init(url: url)), date: datetime
        )
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.syncHttpInvalidResponse.makeError()
        }
        let shouldApply = try await appDb.read { try SyncService.shouldApply(mutation, in: $0) }
        guard shouldApply else { return }

        if url.hasPrefix("http:") {
            guard
                let plugin = await HttpPlugin.fromUrl(
                    String(url.dropFirst("http:".count)), sourceId: sourceId)
            else { throw MankaiErrorCode.browseInvalidPlugin.makeError() }
            try Task.checkCancellation()

            try update(try plugin.databaseModel(), plugin: plugin, mutation: mutation)
        } else if url.hasPrefix("js:") {
            guard
                let plugin = await JsPlugin.fromUrl(
                    String(url.dropFirst("js:".count)), sourceId: sourceId)
            else { throw MankaiErrorCode.browseInvalidPlugin.makeError() }
            try Task.checkCancellation()

            try update(try plugin.databaseModel(), plugin: plugin, mutation: mutation)
        } else {
            throw MankaiErrorCode.browseInvalidPlugin.makeError()
        }
    }

    private func update<Model: PersistableRecord>(
        _ model: Model, plugin: Plugin, mutation: SyncMutation
    ) throws {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.syncHttpInvalidResponse.makeError()
        }
        let sourceId = plugin.id
        let updated = try appDb.write { db in
            guard try SyncService.shouldApply(mutation, in: db) else { return false }
            try JsPluginModel.filter(Column("id") == sourceId).deleteAll(db)
            try HttpPluginModel.filter(Column("id") == sourceId).deleteAll(db)
            try model.save(db)
            return true
        }

        if updated {
            _plugins[sourceId] = wrap(plugin)
            objectWillChange.send()
        }
    }

    /// Downloaded deletions keep the plugin's library and progress and never enqueue a delete.
    func deletePlugin(_ sourceId: String, datetime: Date) throws {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.syncHttpInvalidResponse.makeError()
        }
        let mutation = SyncMutation(
            entry: .plugin(key: .init(sourceId: sourceId), payload: nil), action: .delete,
            date: datetime)
        let deleted = try appDb.write { db in
            guard try SyncService.shouldApply(mutation, in: db) else { return false }
            try JsPluginModel.filter(Column("id") == sourceId).deleteAll(db)
            try HttpPluginModel.filter(Column("id") == sourceId).deleteAll(db)
            return true
        }
        if deleted {
            _plugins[sourceId] = nil
            objectWillChange.send()
        }
    }

    private func loadJsPlugins() {
        Logger.pluginService.debug("Loading JS plugins")
        let jsPlugins = JsPlugin.loadPlugins()
        Logger.pluginService.info("Loaded \(jsPlugins.count) JS plugins")

        for jsPlugin in jsPlugins { _plugins[jsPlugin.id] = wrap(jsPlugin) }

        Task { for jsPlugin in jsPlugins { await jsPlugin.checkForUpdates() } }
    }

    private func loadFsPlugins() {
        Logger.pluginService.debug("Loading FS plugins")
        let fsPlugins = ReadFsPlugin.loadPlugins()
        Logger.pluginService.info("Loaded \(fsPlugins.count) FS plugins")

        for fsPlugin in fsPlugins { _plugins[fsPlugin.id] = wrap(fsPlugin) }
    }

    private func loadHttpPlugins() {
        Logger.pluginService.debug("Loading HTTP plugins")
        let httpPlugins = HttpPlugin.loadPlugins()
        Logger.pluginService.info("Loaded \(httpPlugins.count) HTTP plugins")

        for httpPlugin in httpPlugins { _plugins[httpPlugin.id] = wrap(httpPlugin) }

        Task { for httpPlugin in httpPlugins { await httpPlugin.checkForUpdates() } }
    }

    private func wrap(_ plugin: Plugin) -> Plugin {
        var wrappedPlugin = plugin

        if plugin.cooldown != nil { wrappedPlugin = CooldownWrapper.wrapping(wrappedPlugin) }

        if plugin.shouldCache { wrappedPlugin = CacheWrapper.wrapping(wrappedPlugin) }

        return wrappedPlugin
    }

    /// Retrieves a plugin by its identifier.
    /// - Parameter id: The unique identifier of the plugin.
    /// - Returns: The `Plugin` instance if found, otherwise `nil`.
    func getPlugin(_ id: String) -> Plugin? { return _plugins[id] }

    /// Saves local plugin state, then queues it when it has a portable URL.
    func savePlugin(_ plugin: Plugin) throws {
        try plugin.savePlugin()
        guard let url = plugin.syncURL else { return }
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.syncHttpInvalidResponse.makeError()
        }
        let sourceId = plugin.id
        try appDb.write { db in try SyncService.enqueuePlugin(id: sourceId, url: url, in: db) }
        SyncService.shared.scheduleSync()
    }

    /// Adds a new plugin to the service.
    /// - Parameters:
    ///   - plugin: The `Plugin` instance to add.
    ///   - conflictResolution: How to handle an existing plugin with the same identifier.
    /// - Throws: An error if saving the plugin fails.
    func addPlugin(_ plugin: Plugin, conflictResolution: PluginAddConflictResolution = .reject)
        throws
    {
        Logger.pluginService.debug("Adding plugin: \(plugin.id)")

        let existingPlugin = _plugins[plugin.id]
        if existingPlugin != nil, conflictResolution == .reject {
            Logger.pluginService.warning("Plugin ID already exists: \(plugin.id)")
            throw MankaiErrorCode.pluginDuplicateId.makeError(
                messageArguments: [plugin.id],
                additionalUserInfo: [MankaiErrorUserInfoKey.pluginId: plugin.id])
        }

        do {
            if let existingPlugin { try removePlugin(existingPlugin.id) }
            try savePlugin(plugin)
            _plugins[plugin.id] = wrap(plugin)

            objectWillChange.send()

            Logger.pluginService.info("Plugin added successfully: \(plugin.id)")
        } catch {
            if let existingPlugin {
                do {
                    try savePlugin(existingPlugin)
                    _plugins[plugin.id] = existingPlugin
                    objectWillChange.send()
                } catch {
                    Logger.pluginService.error(
                        "Failed to restore overwritten plugin: \(plugin.id)", error: error)
                }
            }
            Logger.pluginService.error("Failed to save plugin: \(plugin.id)", error: error)
            throw error
        }
    }

    /// Removes a plugin from the service by its identifier.
    /// - Parameter id: The unique identifier of the plugin to remove.
    /// - Throws: An error if deleting the plugin fails.
    func removePlugin(_ id: String) throws {
        Logger.pluginService.debug("Removing plugin: \(id)")
        if let plugin = _plugins[id] {
            do {
                try plugin.deletePlugin()
                if plugin.syncURL != nil {
                    guard let appDb = DbService.shared.appDb else {
                        throw MankaiErrorCode.syncHttpInvalidResponse.makeError()
                    }
                    let mutation = SyncMutation(
                        entry: .plugin(key: .init(sourceId: id), payload: nil), action: .delete)
                    _ = try appDb.write { db in try SyncService.enqueue(mutation, in: db) }
                    SyncService.shared.scheduleSync()
                }
                _plugins[id] = nil
                objectWillChange.send()
                Logger.pluginService.info("Plugin removed successfully: \(id)")
            } catch {
                Logger.pluginService.error("Failed to delete plugin: \(id)", error: error)
                throw error
            }
        } else {
            Logger.pluginService.warning("Plugin not found for removal: \(id)")
        }
    }
}
