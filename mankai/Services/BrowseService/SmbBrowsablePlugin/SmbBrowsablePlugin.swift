//
//  SmbBrowsablePlugin.swift
//  mankai
//
//  Created by Travis XU on 4/8/2026.
//

import Foundation
import GRDB
import SwiftSMB
import SwiftUI

struct SmbConnectionConfiguration: Sendable {
    let host: String
    let port: Int
    let share: String
    var username: String?
    var password: String?

    init(
        host: String, port: Int = 445, share: String, username: String? = nil,
        password: String? = nil
    ) throws {
        let trimmedShare = share.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let normalizedHost = URL.normalizedHost(host), URL.isValidPort(port),
            PathUtilities.isValidComponent(trimmedShare), !trimmedShare.contains("\\")
        else { throw MankaiErrorCode.browseSmbInvalidConnectionConfiguration.makeError() }

        self.host = normalizedHost
        self.port = port
        self.share = trimmedShare
        self.username = username.trimmed
        self.password = password.trimmed
    }

    var server: SMB.Server { SMB.Server(host: host, port: port) }

    var credentials: SMB.Credentials? {
        guard username != nil || password != nil else { return nil }
        return SMB.Credentials(user: username, password: password)
    }
}

/// Owns one authenticated SMB session and recreates it after a connection failure.
actor SmbSession: BrowsableSession {
    typealias Config = SmbConnectionConfiguration

    static let backendName = "SMB"
    static let logger = Logger.smbBrowsablePlugin

    nonisolated let configuration: SmbConnectionConfiguration
    private var connection: SMB.Connection?
    private var connectionTask: Task<SMB.Connection, Error>?

    init(configuration: SmbConnectionConfiguration) { self.configuration = configuration }

    /// Authenticates with an SMB server and returns its browsable disk shares.
    static func discoverShares(host: String, port: Int, username: String?, password: String?)
        async throws -> [SMB.Share]
    {
        let configuration = try SmbConnectionConfiguration(
            host: host, port: port, share: "IPC$", username: username, password: password)

        return
            try SMB.listShares(server: configuration.server, credentials: configuration.credentials)
            .filter { !$0.name.isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        invalidateConnection()
    }

    func list(path: String) async throws -> [BrowsableSessionEntry] {
        try await withConnectedConnection { connection in
            try connection.listDirectory(at: path)
                .map { entry in
                    let isDirectory = entry.stat.type == .directory
                    return BrowsableSessionEntry(
                        name: entry.name, isDirectory: isDirectory, isRegularFile: !isDirectory)
                }
        }
    }

    func download(path: String) async throws -> Data {
        try await withConnectedConnection { connection in try connection.loadFile(at: path) }
    }

    func download(path: String, to localURL: URL) async throws {
        try await withConnectedConnection { connection in
            try connection.downloadFile(remote: path, local: localURL) { completed, total, _, _ in
                let progress = total > 0 ? Double(completed) / Double(total) : 1
                Logger.smbBrowsablePlugin.debug("Downloading \(path): \(Int(progress * 100))%")
                return !Task.isCancelled
            }
            try Task.checkCancellation()
        }
    }

    func upload(data: Data, path: String) async throws {
        try await withConnectedConnection { connection in try connection.dumpToFile(data, to: path)
        }
    }

    func upload(file: URL, path: String) async throws {
        try await withConnectedConnection { connection in
            try connection.uploadFile(local: file, remote: path) { _, _, _, _ in !Task.isCancelled }
            try Task.checkCancellation()
        }
    }

    func createDirectory(path: String) async throws {
        try await withConnectedConnection { connection in
            try connection.makeDirectory(at: path, makePath: true)
        }
    }

    func isOnline() async -> Bool {
        do {
            _ = try await withConnectedConnection { connection in try connection.echo() }
            return true
        } catch { return false }
    }

    func withConnectedConnection<T>(_ operation: (SMB.Connection) throws -> T) async throws -> T {
        if connection?.isConnected != true {
            if let connectionTask {
                connection = try await connectionTask.value
            } else {
                let configuration = configuration
                let task = Task {
                    try SMB.connect(
                        server: configuration.server, credentials: configuration.credentials,
                        share: configuration.share)
                }
                connectionTask = task

                do {
                    connection = try await task.value
                    connectionTask = nil
                } catch {
                    connectionTask = nil
                    throw error
                }
            }
        }

        guard let connection else {
            throw MankaiErrorCode.browseFilesystemEntryNotFound.makeError()
        }

        do { return try operation(connection) } catch {
            invalidateConnection()
            throw error
        }
    }

    private func invalidateConnection() {
        try? connection?.disconnect()
        connection = nil
    }
}

final class SmbBrowsablePlugin: GenericBrowsablePlugin<SmbConnectionConfiguration, SmbSession> {

    /// Creates a new SMB plugin using an existing session.
    convenience init(session: SmbSession, name: String?) async throws {
        do {
            let identity = try await BrowsablePluginUtilities.resolveIdentity(
                using: session,
                invalidPluginError: MankaiErrorCode.browseSmbInvalidPlugin.makeError())

            try self.init(
                id: identity.id, name: name, configuration: session.configuration, session: session,
                shouldSync: identity.shouldSync)
        } catch {
            Logger.smbBrowsablePlugin.error(
                "Failed to create SMB browsable plugin for \(session.configuration.host):\(session.configuration.port)/\(session.configuration.share)",
                error: error)
            await session.disconnect()
            throw error
        }
    }

    init(
        id: String, name: String?, configuration: SmbConnectionConfiguration,
        session: SmbSession? = nil, shouldSync: Bool = true
    ) throws {
        try super
            .init(
                id: id, name: name, configuration: configuration, session: session,
                temporaryDirectoryName: "smb", shouldSync: shouldSync)
    }

    var host: String { configuration.host }

    var port: Int { configuration.port }

    var share: String { configuration.share }

    var username: String? { configuration.username }

    var password: String? { configuration.password }

    override var name: String? {
        displayName ?? (port == 445 ? "\(host)/\(share)" : "\(host):\(port)/\(share)")
    }

    override var tags: [String] { ["SMB"] }

    override var icon: AnyView { AnyView(LabeledFolderIcon(label: "SMB", color: color)) }

    static func loadPlugins() -> [SmbBrowsablePlugin] {
        Logger.smbBrowsablePlugin.debug("Loading SMB browsable plugins")
        guard let dbPool = DbService.shared.appDb else {
            Logger.smbBrowsablePlugin.error("Database not available")
            return []
        }

        let models: [SmbBrowsablePluginModel]
        do { models = try dbPool.read { db in try SmbBrowsablePluginModel.fetchAll(db) } } catch {
            Logger.smbBrowsablePlugin.error(
                "Failed to fetch SmbBrowsablePluginModels", error: error)
            return []
        }

        var results: [SmbBrowsablePlugin] = []
        for model in models {
            do {
                let configuration = try SmbConnectionConfiguration(
                    host: model.host, port: model.port, share: model.share,
                    username: model.username, password: model.password)
                try results.append(
                    SmbBrowsablePlugin(
                        id: model.id, name: model.name, configuration: configuration,
                        shouldSync: model.shouldSync))
            } catch {
                Logger.smbBrowsablePlugin.error(
                    "Failed to load SMB plugin \(model.id)", error: error)
            }
        }
        return results
    }

    override func savePlugin() throws {
        Logger.smbBrowsablePlugin.debug("Saving SMB plugin: \(id)")
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
        }

        let model = SmbBrowsablePluginModel(
            id: id, name: displayName, host: host, port: port, share: share, username: username,
            password: password, shouldSync: shouldSync)
        try db.write { db in try model.save(db) }
    }

    override func deletePlugin() throws {
        Logger.smbBrowsablePlugin.debug("Deleting SMB plugin: \(id)")
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
        }

        _ = try db.write { db in try SmbBrowsablePluginModel.deleteOne(db, key: id) }
        try super.deletePlugin()
    }
}
