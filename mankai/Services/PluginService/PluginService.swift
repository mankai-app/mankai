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

    /// Each loader owns its stored instances, including any editable variants.
    private static let pluginTypes: [Plugin.Type] = [
        AppDirPlugin.self, JsPlugin.self, ReadFsPlugin.self, HttpPlugin.self
    ]

    private init() {
        Logger.pluginService.debug("Initializing PluginService")

        loadPlugins()
    }

    private var _plugins: [String: Plugin] = [:]

    /// A list of all available plugins.
    var plugins: [Plugin] { return Array(_plugins.values) }

    /// Selects the registered decoder using the explicit plugin type.
    func decodeURL(_ url: String, type: String, sourceId: String? = nil) async -> Plugin? {
        guard !Task.isCancelled,
            let pluginType = Self.pluginTypes.first(where: {
                $0.syncType == type && $0.typeCapabilities.contains(.urlDecoding)
            })
        else { return nil }
        let plugin = await pluginType.decodeURL(url, sourceId: sourceId)
        return Task.isCancelled ? nil : plugin
    }

    /// Reconstruct and save a downloaded plugin without queueing it again.
    func updatePlugin(url: String, type: String, sourceId: String, datetime: Date) async throws {
        if let plugin = _plugins[sourceId], plugin.syncType == type, plugin.supports(.urlEncoding),
            plugin.encodeURL() == url
        {
            return
        }
        let mutation = SyncMutation(
            entry: .plugin(key: .init(sourceId: sourceId), payload: .init(url: url, type: type)),
            date: datetime)
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.syncHttpInvalidResponse.makeError()
        }
        let shouldApply = try await appDb.read { try SyncService.shouldApply(mutation, in: $0) }
        guard shouldApply else { return }

        let decodedPlugin = await decodeURL(url, type: type, sourceId: sourceId)
        try Task.checkCancellation()
        guard let plugin = decodedPlugin, plugin.typeCapabilities.contains(.urlDecoding) else {
            throw MankaiErrorCode.browseInvalidPlugin.makeError()
        }

        try update(try plugin.databaseModel(), plugin: plugin, mutation: mutation)
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
            try deleteStoredPlugins(sourceId, in: db)
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
            try deleteStoredPlugins(sourceId, in: db)
            return true
        }
        if deleted {
            _plugins[sourceId] = nil
            objectWillChange.send()
        }
    }

    private func deleteStoredPlugins(_ sourceId: String, in db: Database) throws {
        for pluginType in Self.pluginTypes where pluginType.typeCapabilities.contains(.urlDecoding)
        { try pluginType.deleteStoredPlugin(sourceId, in: db) }
    }

    private func loadPlugins() {
        for pluginType in Self.pluginTypes {
            let plugins = pluginType.loadPlugins()
            Logger.pluginService.info("Loaded \(plugins.count) plugins from \(pluginType)")
            for plugin in plugins { _plugins[plugin.id] = wrap(plugin) }
        }
    }

    private func wrap(_ plugin: Plugin) -> Plugin {
        var wrappedPlugin = plugin

        if plugin.cooldown != nil { wrappedPlugin = CooldownWrapper.wrapping(wrappedPlugin) }

        if plugin.typeCapabilities.contains(.cache) {
            wrappedPlugin = CacheWrapper.wrapping(wrappedPlugin)
        }

        return wrappedPlugin
    }

    /// Retrieves a plugin by its identifier.
    /// - Parameter id: The unique identifier of the plugin.
    /// - Returns: The `Plugin` instance if found, otherwise `nil`.
    func getPlugin(_ id: String) -> Plugin? { return _plugins[id] }

    /// Saves portable settings and their pending mutation in the same transaction.
    func savePlugin(_ plugin: Plugin) throws {
        guard plugin.supports(.urlEncoding), let type = plugin.syncType else {
            try plugin.savePlugin()
            return
        }

        try save(try plugin.databaseModel(), plugin: plugin, type: type)
        SyncService.shared.scheduleSync()
    }

    private func save<Model: PersistableRecord>(_ model: Model, plugin: Plugin, type: String) throws
    {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.syncInvalidResponse.makeError()
        }
        let url = plugin.encodeURL()
        try appDb.write { db in
            let storedURL = try Self.pluginTypes.first(where: { $0.syncType == type })?
                .loadStoredURL(plugin.id, in: db)

            if storedURL != url {
                try SyncService.enqueuePlugin(id: plugin.id, url: url, type: type, in: db)
            }

            try model.save(db)
        }
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
                if plugin.supports(.urlEncoding) {
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
