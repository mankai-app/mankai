//
//  BrowseService.swift
//  mankai
//
//  Created by Travis XU on 13/7/2026.
//

import Foundation
import GRDB
import SwiftUI

struct Entity {
    enum Kind {
        case book(fileType: String)
        case directory
    }

    let path: String
    let displayName: String
    let name: String
    let type: Kind

    /// Display name for a file after its manga metadata has been parsed.
    func displayName(using manga: DetailedManga?) -> String {
        guard case .book(_) = type, let manga else { return displayName }

        let allChapters = manga.chapters.flatMap(\.chapters)
        if allChapters.count == 1, let chapterTitle = allChapters.first?.title {
            return chapterTitle
        }
        return manga.title ?? displayName
    }
}

@MainActor protocol Browsable {
    /// An optional user-defined display name for the plugin.
    ///
    /// When `nil`, the plugin uses its backend-specific default name.
    var displayName: String? { get set }

    /// The icon used to represent this plugin.
    var icon: AnyView { get }

    /// The color used to visually distinguish this plugin.
    var color: Color { get }

    /// Returns the entities at the given path.
    func getEntities(path: String?) async throws -> [Entity]

    /// Parses a supported manga file at the given path.
    func parseFile(path: String, fileType: String) async throws -> DetailedManga

    /// Returns the absolute filesystem URL for the given relative path,
    /// if the plugin is backed by a local filesystem directory.
    /// Returns `nil` for non-filesystem plugins.
    /// - Parameter path: A path relative to the plugin's root, or `nil` for the root.
    func absoluteURL(for path: String?) -> URL?
}

/// A plugin that can receive files from the system file importer.
@MainActor protocol Importable {
    /// The file extensions accepted by this importable plugin.
    var supportedExtensions: [String] { get }

    /// The directory entity inside the plugin used for imported files.
    var importsEntity: Entity { get }

    /// Imports a file from the given URL into the plugin's import directory.
    ///
    /// The caller is responsible for ensuring the source resource is accessible (e.g. by starting security-scoped access if needed).
    ///
    /// - Parameter source: The URL of the file to import.
    func importFile(from source: URL) async throws
}

typealias BrowsablePlugin = Browsable & Plugin
typealias ImportableBrowsablePlugin = Browsable & Importable & Plugin

@MainActor protocol LocalBrowsablePluginConvertible { func convertToLocalPlugin() }

enum BrowsePluginAddConflictResolution {
    case reject
    case overwrite
    case makeLocal
}

@MainActor final class BrowseService: ObservableObject {
    static let shared = BrowseService()

    /// Each type loads its saved instances, including the built-in folder.
    private static let pluginTypes: [Plugin.Type] = [
        AppDirBrowsablePlugin.self, FsBrowsablePlugin.self, SmbBrowsablePlugin.self,
        SftpBrowsablePlugin.self, NfsBrowsablePlugin.self, WebDavBrowsablePlugin.self,
        OpdsBrowsablePlugin.self
    ]

    private init() {
        Logger.browseService.debug("Initializing BrowseService")

        loadPlugins()
    }

    private var _plugins: [String: BrowsablePlugin] = [:]

    /// A list of all available plugins, with `AppDirBrowsablePlugin` always placed first.
    var plugins: [BrowsablePlugin] {
        let appDir = AppDirBrowsablePlugin.shared
        let others = _plugins.values.filter { $0.id != appDir.id }.sorted { $0.id < $1.id }
        return [appDir] + others
    }

    /// A list of plugins that can receive files from the system file importer.
    var importablePlugins: [ImportableBrowsablePlugin] {
        plugins.compactMap { $0 as? ImportableBrowsablePlugin }
    }

    private func loadPlugins() {
        for pluginType in Self.pluginTypes {
            let plugins = pluginType.loadPlugins().compactMap { $0 as? BrowsablePlugin }
            Logger.browseService.info(
                "Loaded \(plugins.count) browsable plugins from \(pluginType)")
            for plugin in plugins { _plugins[plugin.id] = plugin }
        }
    }

    /// Retrieves a plugin by its identifier.
    /// - Parameter id: The unique identifier of the plugin.
    /// - Returns: The `BrowsablePlugin` instance if found, otherwise `nil`.
    func getPlugin(_ id: String) -> BrowsablePlugin? { return _plugins[id] }

    /// Retrieves an importable plugin by its identifier.
    func getImportablePlugin(_ id: String) -> ImportableBrowsablePlugin? {
        _plugins[id] as? ImportableBrowsablePlugin
    }

    /// Reconstructs a downloaded folder configuration without contacting its server or requeueing it.
    func updatePlugin(url: String, type: String, sourceId: String, datetime: Date) async throws {
        if let plugin = _plugins[sourceId] {
            guard plugin.supports(.urlEncoding) else {
                throw MankaiErrorCode.browseInvalidPlugin.makeError()
            }
            if plugin.syncType == type, plugin.encodeURL() == url { return }
        }
        let mutation = SyncMutation(
            entry: .browsableplugin(
                key: .init(sourceId: sourceId), payload: .init(url: url, type: type)),
            date: datetime)
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.syncInvalidResponse.makeError()
        }
        guard try await appDb.read({ try SyncService.shouldApply(mutation, in: $0) }) else {
            return
        }
        guard
            let pluginType = Self.pluginTypes.first(where: {
                $0.syncType == type && $0.typeCapabilities.contains(.urlDecoding)
            }), let plugin = await pluginType.decodeURL(url, sourceId: sourceId) as? BrowsablePlugin
        else { throw MankaiErrorCode.browseInvalidPlugin.makeError() }
        try Task.checkCancellation()
        try update(try plugin.databaseModel(), plugin: plugin, mutation: mutation)
    }

    private func update<Model: PersistableRecord>(
        _ model: Model, plugin: BrowsablePlugin, mutation: SyncMutation
    ) throws {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.syncInvalidResponse.makeError()
        }
        let updated = try appDb.write { db in
            guard try SyncService.shouldApply(mutation, in: db) else { return false }
            try deleteStoredPlugins(plugin.id, in: db)
            try model.save(db)
            return true
        }
        if updated {
            _plugins[plugin.id] = plugin
            objectWillChange.send()
        }
    }

    /// Remote deletions retain library, progress, and local filesystem folders.
    func deletePlugin(_ sourceId: String, datetime: Date) throws {
        if let plugin = _plugins[sourceId], !plugin.supports(.urlEncoding) { return }
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.syncInvalidResponse.makeError()
        }
        let mutation = SyncMutation(
            entry: .browsableplugin(key: .init(sourceId: sourceId), payload: nil), action: .delete,
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

    /// Saves portable settings and their pending mutation in the same transaction.
    func savePlugin(_ plugin: BrowsablePlugin) throws {
        guard plugin.supports(.urlEncoding), let type = plugin.syncType else {
            try plugin.savePlugin()
            return
        }

        try save(try plugin.databaseModel(), plugin: plugin, type: type)
        SyncService.shared.scheduleSync()
    }

    private func save<Model: PersistableRecord>(
        _ model: Model, plugin: BrowsablePlugin, type: String
    ) throws {
        guard let appDb = DbService.shared.appDb else {
            throw MankaiErrorCode.syncInvalidResponse.makeError()
        }
        let url = plugin.encodeURL()
        try appDb.write { db in
            let storedURL = try Self.pluginTypes.first(where: { $0.syncType == type })?
                .loadStoredURL(plugin.id, in: db)
            if storedURL != url {
                try SyncService.enqueuePlugin(
                    id: plugin.id, url: url, type: type, browsable: true, in: db)
            }
            try model.save(db)
        }
    }

    /// Adds a new plugin to the service.
    /// - Parameters:
    ///   - plugin: The `BrowsablePlugin` instance to add.
    ///   - conflictResolution: How to handle an existing plugin with the same identifier.
    /// - Throws: An error if saving the plugin fails.
    func addPlugin(
        _ plugin: BrowsablePlugin, conflictResolution: BrowsePluginAddConflictResolution = .reject
    ) throws {
        let originalPluginID = plugin.id
        let existingPlugin = _plugins[originalPluginID]
        var shouldOverwriteExisting = false

        if existingPlugin != nil {
            switch conflictResolution { case .reject:
                Logger.browseService.warning("Plugin ID already exists: \(plugin.id)")
                throw MankaiErrorCode.pluginDuplicateId.makeError(
                    messageOverride: String(localized: "duplicateShareIdMessageFormat"),
                    messageArguments: [plugin.id],
                    additionalUserInfo: [MankaiErrorUserInfoKey.pluginId: plugin.id])
                case .overwrite: shouldOverwriteExisting = true
                case .makeLocal:
                    guard let convertible = plugin as? LocalBrowsablePluginConvertible else {
                        throw MankaiErrorCode.browseInvalidPlugin.makeError()
                    }
                    convertible.convertToLocalPlugin()
            }
        }

        if plugin.id != originalPluginID, _plugins[plugin.id] != nil {
            Logger.browseService.warning("Local plugin ID already exists: \(plugin.id)")
            throw MankaiErrorCode.pluginDuplicateId.makeError(
                messageOverride: String(localized: "duplicateShareIdMessageFormat"),
                messageArguments: [plugin.id],
                additionalUserInfo: [MankaiErrorUserInfoKey.pluginId: plugin.id])
        }

        Logger.browseService.debug("Adding plugin: \(plugin.id)")
        do {
            if shouldOverwriteExisting, let existingPlugin { try existingPlugin.deletePlugin() }
            try savePlugin(plugin)
            _plugins[plugin.id] = plugin

            objectWillChange.send()

            Logger.browseService.info("Plugin added successfully: \(plugin.id)")
        } catch {
            if shouldOverwriteExisting, let existingPlugin {
                do { try savePlugin(existingPlugin) } catch {
                    Logger.browseService.error(
                        "Failed to restore overwritten plugin: \(originalPluginID)", error: error)
                }
            }
            Logger.browseService.error("Failed to save plugin: \(plugin.id)", error: error)
            throw error
        }
    }

    /// Removes a plugin from the service by its identifier.
    /// - Parameter id: The unique identifier of the plugin to remove.
    /// - Throws: An error if deleting the plugin fails.
    func removePlugin(_ id: String) throws {
        Logger.browseService.debug("Removing plugin: \(id)")
        if let plugin = _plugins[id] {
            do {
                try plugin.deletePlugin()

                if plugin.supports(.urlEncoding) {
                    guard let appDb = DbService.shared.appDb else {
                        throw MankaiErrorCode.syncInvalidResponse.makeError()
                    }
                    let mutation = SyncMutation(
                        entry: .browsableplugin(key: .init(sourceId: id), payload: nil),
                        action: .delete)
                    _ = try appDb.write { try SyncService.enqueue(mutation, in: $0) }
                    SyncService.shared.scheduleSync()
                }

                _plugins[id] = nil
                objectWillChange.send()
                Logger.browseService.info("Plugin removed successfully: \(id)")
            } catch {
                Logger.browseService.error("Failed to delete plugin: \(id)", error: error)
                throw error
            }
        } else {
            Logger.browseService.warning("Plugin not found for removal: \(id)")
        }
    }
}
