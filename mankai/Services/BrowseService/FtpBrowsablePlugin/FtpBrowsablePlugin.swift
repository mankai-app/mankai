//
//  FtpBrowsablePlugin.swift
//  mankai
//
//  Created by Travis XU on 26/11/2026.
//

import Foundation
import GRDB
import SwiftUI

final class FtpBrowsablePlugin: GenericBrowsablePlugin<FtpConnectionConfiguration, FtpSession> {
    /// Creates a new FTP plugin after validating the connection and resolving its identity.
    convenience init(session: FtpSession, name: String?) async throws {
        do {
            let identity = try await BrowsablePluginUtilities.resolveIdentity(
                using: session,
                invalidPluginError: MankaiErrorCode.browseFtpInvalidPlugin.makeError())

            try Task.checkCancellation()
            try self.init(
                id: identity.id, name: name, configuration: session.configuration, session: session,
                shouldSync: identity.shouldSync)
        } catch {
            Logger.ftpBrowsablePlugin.error(
                "Failed to create FTP browsable plugin for \(session.configuration.host):\(session.configuration.port)",
                error: error)
            await session.disconnect()
            throw error
        }
    }

    init(
        id: String, name: String?, configuration: FtpConnectionConfiguration,
        session: FtpSession? = nil, shouldSync: Bool = true
    ) throws {
        try super
            .init(
                id: id, name: name, configuration: configuration, session: session,
                temporaryDirectoryName: "ftp", shouldSync: shouldSync)
    }

    var host: String { configuration.host }
    var port: Int { configuration.port }
    var username: String { configuration.username }
    var password: String { configuration.password }

    override var name: String? {
        if let displayName { return displayName }
        let displayedHost = host.contains(":") ? "[\(host)]" : host
        let account = username.isEmpty ? displayedHost : "\(username)@\(displayedHost)"
        return port == configuration.transferProtocol.defaultPort ? account : "\(account):\(port)"
    }

    override var tags: [String] { [configuration.transferProtocol.tag] }

    override class var defaultIcon: PluginIcon { .folder("FTP") }

    override class var defaultColor: Color { .green }

    override class var syncType: String? { "ftp" }

    override class var typeCapabilities: [PluginTypeCapability] { [.urlDecoding] }

    override func encodeURL() -> String { BrowsablePluginUtilities.encode(model) }

    override class func decodeURL(_ url: String, sourceId: String? = nil) async -> Plugin? {
        guard var model: FtpBrowsablePluginModel = BrowsablePluginUtilities.decode(url) else {
            return nil
        }
        if let sourceId { model.id = sourceId }
        return try? fromDataModel(model)
    }

    private static func fromDataModel(_ model: FtpBrowsablePluginModel) throws -> FtpBrowsablePlugin
    {
        let configuration = try FtpConnectionConfiguration(
            transferProtocol: model.transferProtocol, host: model.host, port: model.port,
            username: model.username, password: model.password)
        return try FtpBrowsablePlugin(
            id: model.id, name: model.name, configuration: configuration,
            shouldSync: model.shouldSync)
    }

    override class func loadStoredURL(_ id: String, in db: Database) throws -> String? {
        try FtpBrowsablePluginModel.fetchOne(db, key: id)
            .map { BrowsablePluginUtilities.encode($0) }
    }

    override class func deleteStoredPlugin(_ id: String, in db: Database) throws {
        _ = try FtpBrowsablePluginModel.deleteOne(db, key: id)
    }

    private var model: FtpBrowsablePluginModel {
        FtpBrowsablePluginModel(
            id: id, name: displayName, host: host, port: port, username: username,
            password: password, shouldSync: supports(.sync),
            transferProtocol: configuration.transferProtocol)
    }

    override class func loadPlugins() -> [Plugin] {
        Logger.ftpBrowsablePlugin.debug("Loading FTP browsable plugins")
        guard let dbPool = DbService.shared.appDb else {
            Logger.ftpBrowsablePlugin.error("Database not available")
            return []
        }

        let models: [FtpBrowsablePluginModel]
        do { models = try dbPool.read { db in try FtpBrowsablePluginModel.fetchAll(db) } } catch {
            Logger.ftpBrowsablePlugin.error(
                "Failed to fetch FtpBrowsablePluginModels", error: error)
            return []
        }

        var results: [FtpBrowsablePlugin] = []
        for model in models {
            do { try results.append(fromDataModel(model)) } catch {
                Logger.ftpBrowsablePlugin.error(
                    "Failed to load FTP plugin \(model.id)", error: error)
            }
        }
        return results
    }

    override func savePlugin(db: Database? = nil) throws {
        Logger.ftpBrowsablePlugin.debug("Saving FTP plugin: \(id)")
        let model = model
        if let db {
            try model.save(db)
        } else {
            guard let dbPool = DbService.shared.appDb else {
                throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
            }
            try dbPool.write { db in try model.save(db) }
        }
    }

    override func deletePlugin() throws {
        Logger.ftpBrowsablePlugin.debug("Deleting FTP plugin: \(id)")
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
        }

        _ = try db.write { db in try FtpBrowsablePluginModel.deleteOne(db, key: id) }
        try super.deletePlugin()
    }
}
