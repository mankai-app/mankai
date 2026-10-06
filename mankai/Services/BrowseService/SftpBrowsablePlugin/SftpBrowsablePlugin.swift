//
//  SftpBrowsablePlugin.swift
//  mankai
//
//  Created by Travis XU on 31/8/2026.
//

@preconcurrency import Citadel
import Foundation
import GRDB
import SwiftUI

struct SftpConnectionConfiguration: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String

    init(host: String, port: Int = 22, username: String, password: String) throws {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let normalizedHost = URL.normalizedHost(host), URL.isValidPort(port),
            !trimmedUsername.isEmpty, !trimmedUsername.contains("\0"), !password.contains("\0")
        else { throw MankaiErrorCode.browseSftpInvalidConnectionConfiguration.makeError() }

        self.host = normalizedHost
        self.port = port
        self.username = trimmedUsername
        self.password = password
    }
}

/// Owns one SSH/SFTP connection and recreates it after a failed operation.
actor SftpSession: BrowsableSession {
    typealias Config = SftpConnectionConfiguration
    private typealias OpenedConnection = (
        sshClient: SSHClient, sftpClient: SFTPClient, rootPath: String
    )

    static let backendName = "sftp"
    static let logger = Logger.sftpBrowsablePlugin

    nonisolated let configuration: SftpConnectionConfiguration

    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?
    private var canonicalRootPath: String?
    private var connectionTask: Task<OpenedConnection, Error>?

    init(configuration: SftpConnectionConfiguration) { self.configuration = configuration }

    func disconnect() async {
        connectionTask?.cancel()
        connectionTask = nil
        await invalidateConnection()
    }

    func list(path: String) async throws -> [BrowsableSessionEntry] {
        try await withConnectedClient(path: path) { client, remotePath in
            let pages = try await client.listDirectory(atPath: remotePath)
            let components = pages.flatMap(\.components)
            var entries: [BrowsableSessionEntry] = []

            for component in components {
                var attributes = component.attributes
                var kind = Self.entryKind(attributes: attributes, longName: component.longname)
                if kind == nil {
                    let childPath = PathUtilities.appending(component.filename, to: remotePath)
                    if let resolvedAttributes = try? await client.getAttributes(at: childPath) {
                        attributes = resolvedAttributes
                        kind = Self.entryKind(attributes: attributes, longName: component.longname)
                    }
                }

                entries.append(
                    BrowsableSessionEntry(
                        name: component.filename, isDirectory: kind == .directory,
                        isRegularFile: kind == .regularFile))
            }
            return entries
        }
    }

    func download(path: String) async throws -> Data {
        try await withConnectedClient(path: path) { client, remotePath in
            let buffer = try await client.withFile(filePath: remotePath, flags: .read) { file in
                try await file.readAll()
            }
            return Data(buffer.readableBytesView)
        }
    }

    func upload(data: Data, path: String) async throws {
        try await withConnectedClient(path: path) { client, remotePath in
            try await client.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) {
                file in
                try Task.checkCancellation()
                try await file.write(.init(bytes: data))
            }
        }
    }

    func upload(file: URL, path: String) async throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        try Task.checkCancellation()
        try await upload(data: data, path: path)
    }

    func createDirectory(path: String) async throws {
        try await withConnectedClient(path: path) { client, remotePath in
            try await client.createDirectory(atPath: remotePath)
        }
    }

    private enum EntryKind: Equatable { case directory, regularFile }

    private static func entryKind(attributes: SFTPFileAttributes, longName: String) -> EntryKind? {
        if let permissions = attributes.permissions {
            switch permissions & 0o170000 { case 0o040000: return .directory case 0o100000:
                return .regularFile
                default: break
            }
        }

        switch longName.first { case "d": return .directory case "-": return .regularFile default:
            return nil
        }
    }

    private func withConnectedClient<T>(
        path: String, operation: (SFTPClient, String) async throws -> T
    ) async throws -> T {
        if sshClient?.isConnected != true || sftpClient?.isActive != true
            || canonicalRootPath == nil
        {
            if let connectionTask {
                let connection = try await connectionTask.value
                sshClient = connection.sshClient
                sftpClient = connection.sftpClient
                canonicalRootPath = connection.rootPath
            } else {
                let configuration = configuration
                let task = Task<OpenedConnection, Error> {
                    let settings = SSHClientSettings(
                        host: configuration.host, port: configuration.port,
                        authenticationMethod: {
                            .passwordBased(
                                username: configuration.username, password: configuration.password)
                        }, hostKeyValidator: .acceptAnything())

                    var openedSSHClient: SSHClient?
                    var openedSftpClient: SFTPClient?
                    do {
                        let sshClient = try await SSHClient.connect(to: settings)
                        openedSSHClient = sshClient
                        let sftpClient = try await sshClient.openSFTP()
                        openedSftpClient = sftpClient
                        let rootPath = try await sftpClient.getRealPath(atPath: ".")
                        _ = try await sftpClient.listDirectory(atPath: rootPath)
                        return (sshClient, sftpClient, rootPath)
                    } catch {
                        try? await openedSftpClient?.close()
                        try? await openedSSHClient?.close()
                        throw error
                    }
                }
                connectionTask = task

                do {
                    let connection = try await task.value
                    sshClient = connection.sshClient
                    sftpClient = connection.sftpClient
                    canonicalRootPath = connection.rootPath
                    connectionTask = nil
                } catch {
                    connectionTask = nil
                    throw error
                }
            }
        }

        guard let sftpClient, let canonicalRootPath else {
            throw MankaiErrorCode.browseSftpInvalidPlugin.makeError()
        }
        let remotePath =
            path.isEmpty ? canonicalRootPath : PathUtilities.appending(path, to: canonicalRootPath)

        do { return try await operation(sftpClient, remotePath) } catch {
            await invalidateConnection()
            throw error
        }
    }

    private func invalidateConnection() async {
        let sftpClient = self.sftpClient
        let sshClient = self.sshClient
        self.sftpClient = nil
        self.sshClient = nil
        canonicalRootPath = nil

        try? await sftpClient?.close()
        try? await sshClient?.close()
    }
}

final class SftpBrowsablePlugin: GenericBrowsablePlugin<SftpConnectionConfiguration, SftpSession> {
    /// Creates a new SFTP plugin after validating the connection and resolving its identity.
    convenience init(session: SftpSession, name: String?) async throws {
        do {
            let identity = try await BrowsablePluginUtilities.resolveIdentity(
                using: session,
                invalidPluginError: MankaiErrorCode.browseSftpInvalidPlugin.makeError())

            try self.init(
                id: identity.id, name: name, configuration: session.configuration, session: session,
                shouldSync: identity.shouldSync)
        } catch {
            Logger.sftpBrowsablePlugin.error(
                "Failed to create SFTP browsable plugin for \(session.configuration.host):\(session.configuration.port)",
                error: error)
            await session.disconnect()
            throw error
        }
    }

    init(
        id: String, name: String?, configuration: SftpConnectionConfiguration,
        session: SftpSession? = nil, shouldSync: Bool = true
    ) throws {
        try super
            .init(
                id: id, name: name, configuration: configuration, session: session,
                temporaryDirectoryName: "sftp", shouldSync: shouldSync)
    }

    var host: String { configuration.host }
    var port: Int { configuration.port }
    var username: String { configuration.username }
    var password: String { configuration.password }

    override var name: String? {
        if let displayName { return displayName }
        let displayedHost = host.contains(":") ? "[\(host)]" : host
        return port == 22 ? "\(username)@\(displayedHost)" : "\(username)@\(displayedHost):\(port)"
    }

    override var tags: [String] { ["SFTP"] }

    override var icon: AnyView { AnyView(LabeledFolderIcon(label: "SSH", color: color)) }

    override class func loadPlugins() -> [Plugin] {
        Logger.sftpBrowsablePlugin.debug("Loading SFTP browsable plugins")
        guard let dbPool = DbService.shared.appDb else {
            Logger.sftpBrowsablePlugin.error("Database not available")
            return []
        }

        let models: [SftpBrowsablePluginModel]
        do { models = try dbPool.read { db in try SftpBrowsablePluginModel.fetchAll(db) } } catch {
            Logger.sftpBrowsablePlugin.error(
                "Failed to fetch SftpBrowsablePluginModels", error: error)
            return []
        }

        var results: [SftpBrowsablePlugin] = []
        for model in models {
            do {
                let configuration = try SftpConnectionConfiguration(
                    host: model.host, port: model.port, username: model.username,
                    password: model.password)
                try results.append(
                    SftpBrowsablePlugin(
                        id: model.id, name: model.name, configuration: configuration,
                        shouldSync: model.shouldSync))
            } catch {
                Logger.sftpBrowsablePlugin.error(
                    "Failed to load SFTP plugin \(model.id)", error: error)
            }
        }
        return results
    }

    override func savePlugin() throws {
        Logger.sftpBrowsablePlugin.debug("Saving SFTP plugin: \(id)")
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
        }

        let model = SftpBrowsablePluginModel(
            id: id, name: displayName, host: host, port: port, username: username,
            password: password, shouldSync: supports(.sync))
        try db.write { db in try model.save(db) }
    }

    override func deletePlugin() throws {
        Logger.sftpBrowsablePlugin.debug("Deleting SFTP plugin: \(id)")
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
        }

        _ = try db.write { db in try SftpBrowsablePluginModel.deleteOne(db, key: id) }
        try super.deletePlugin()
    }
}
