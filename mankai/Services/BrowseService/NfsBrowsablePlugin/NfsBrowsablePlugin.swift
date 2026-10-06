//
//  NfsBrowsablePlugin.swift
//  mankai
//
//  Created by Travis XU on 28/8/2026.
//

import Foundation
import GRDB
@preconcurrency import NFSKit
import SwiftUI

struct NfsConnectionConfiguration: Sendable {
    let host: String
    let export: String

    init(host: String, export: String) throws {
        let trimmedExport = export.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let normalizedHost = URL.normalizedHost(host),
            URL.serverURL(scheme: "nfs", host: normalizedHost) != nil,
            PathUtilities.isValidAbsolutePath(trimmedExport)
        else { throw MankaiErrorCode.browseNfsInvalidConnectionConfiguration.makeError() }

        self.host = normalizedHost
        self.export = trimmedExport
    }

    var serverURL: URL {
        // Validation in the initializer guarantees this URL can be built.
        URL.serverURL(scheme: "nfs", host: host)!
    }
}

/// Owns one mounted NFS client and remounts the export after a failed operation.
actor NfsSession: BrowsableSession {
    typealias Config = NfsConnectionConfiguration

    static let backendName = "NFS"
    static let logger = Logger.nfsBrowsablePlugin

    nonisolated let configuration: NfsConnectionConfiguration

    private var client: NFSClient?
    private var connectionTask: Task<NFSClient, Error>?

    init(configuration: NfsConnectionConfiguration) { self.configuration = configuration }

    /// Returns the exports advertised by an NFS server.
    static func discoverExports(host: String) async throws -> [String] {
        guard let normalizedHost = URL.normalizedHost(host),
            let url = URL.serverURL(scheme: "nfs", host: normalizedHost)
        else { throw MankaiErrorCode.browseNfsInvalidConnectionConfiguration.makeError() }
        guard let client = try NFSClient(url: url) else {
            throw MankaiErrorCode.browseNfsInvalidConnectionConfiguration.makeError()
        }

        let exports: [String] = try await withCheckedThrowingContinuation { continuation in
            client.listExports { result in continuation.resume(with: result) }
        }
        return Array(Set(exports.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func disconnect() async {
        connectionTask?.cancel()
        connectionTask = nil

        guard let client else { return }
        self.client = nil
        await withCheckedContinuation { continuation in
            client.disconnect(export: configuration.export, gracefully: true) { _ in
                continuation.resume()
            }
        }
    }

    func list(path: String) async throws -> [BrowsableSessionEntry] {
        let client = try await connectedClient()
        let nfsPath = path.isEmpty ? "/" : path

        do {
            return try await withCheckedThrowingContinuation { continuation in
                client.contentsOfDirectory(atPath: nfsPath) { result in
                    switch result { case .success(let values):
                        let entries: [BrowsableSessionEntry] = values.compactMap {
                            value -> BrowsableSessionEntry? in
                            guard let name = value[.nameKey] as? String else { return nil }
                            let type = value[.fileResourceTypeKey] as? URLFileResourceType
                            return BrowsableSessionEntry(
                                name: name, isDirectory: type == .directory,
                                isRegularFile: type == .regular)
                        }
                        continuation.resume(returning: entries)
                        case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            invalidate(client)
            throw error
        }
    }

    func download(path: String) async throws -> Data {
        let client = try await connectedClient()
        do {
            return try await withCheckedThrowingContinuation { continuation in
                client.contents(atPath: path, progress: nil) { result in
                    continuation.resume(with: result)
                }
            }
        } catch {
            invalidate(client)
            throw error
        }
    }

    func download(path: String, to localURL: URL) async throws {
        let client = try await connectedClient()
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                client.downloadItem(
                    atPath: path, to: localURL,
                    progress: { completed, total in
                        let progress = total > 0 ? Double(completed) / Double(total) : 1
                        Logger.nfsBrowsablePlugin.debug(
                            "Downloading \(path): \(Int(progress * 100))%")
                        return true
                    }
                ) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            invalidate(client)
            throw error
        }
    }

    func createDirectory(path: String) async throws {
        let client = try await connectedClient()
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                client.createDirectory(atPath: path) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            invalidate(client)
            throw error
        }
    }

    func upload(data: Data, path: String) async throws {
        let client = try await connectedClient()
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                client.write(data: data, toPath: path, progress: { _ in true }) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            invalidate(client)
            throw error
        }
    }

    func upload(file: URL, path: String) async throws {
        let client = try await connectedClient()
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                client.uploadItem(at: file, toPath: path, progress: { _ in true }) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            invalidate(client)
            throw error
        }
    }

    private func connectedClient() async throws -> NFSClient {
        if let client { return client }

        if let connectionTask {
            let client = try await connectionTask.value
            self.client = client
            return client
        }

        let configuration = configuration
        let task = Task {
            guard let client = try NFSClient(url: configuration.serverURL) else {
                throw MankaiErrorCode.browseNfsInvalidConnectionConfiguration.makeError()
            }

            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                client.connect(export: configuration.export) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            return client
        }
        connectionTask = task

        do {
            client = try await task.value
            connectionTask = nil
        } catch {
            connectionTask = nil
            throw error
        }

        guard let client else { throw MankaiErrorCode.browseNfsInvalidPlugin.makeError() }
        return client
    }

    private func invalidate(_ failedClient: NFSClient) {
        if client === failedClient { client = nil }
    }
}

final class NfsBrowsablePlugin: GenericBrowsablePlugin<NfsConnectionConfiguration, NfsSession> {

    /// Creates a new NFS plugin after mounting the export and resolving its identity.
    convenience init(session: NfsSession, name: String?) async throws {
        do {
            let identity = try await BrowsablePluginUtilities.resolveIdentity(
                using: session,
                invalidPluginError: MankaiErrorCode.browseNfsInvalidPlugin.makeError())

            try self.init(
                id: identity.id, name: name, configuration: session.configuration, session: session,
                shouldSync: identity.shouldSync)
        } catch {
            Logger.nfsBrowsablePlugin.error(
                "Failed to create NFS browsable plugin for \(session.configuration.host)\(session.configuration.export)",
                error: error)
            await session.disconnect()
            throw error
        }
    }

    init(
        id: String, name: String?, configuration: NfsConnectionConfiguration,
        session: NfsSession? = nil, shouldSync: Bool = true
    ) throws {
        try super
            .init(
                id: id, name: name, configuration: configuration, session: session,
                temporaryDirectoryName: "nfs", shouldSync: shouldSync)
    }

    var host: String { configuration.host }

    var export: String { configuration.export }

    override var name: String? { displayName ?? "\(host)\(export)" }

    override var tags: [String] { ["NFS"] }

    override var icon: AnyView { AnyView(LabeledFolderIcon(label: "NFS", color: color)) }

    override class var syncType: String? { "nfs" }

    override class var typeCapabilities: [PluginTypeCapability] { [.urlDecoding] }

    override func encodeURL() -> String { BrowsablePluginUtilities.encode(model) }

    override class func decodeURL(_ url: String, sourceId: String? = nil) async -> Plugin? {
        guard var model: NfsBrowsablePluginModel = BrowsablePluginUtilities.decode(url) else {
            return nil
        }
        if let sourceId { model.id = sourceId }
        return try? fromDataModel(model)
    }

    private static func fromDataModel(_ model: NfsBrowsablePluginModel) throws -> NfsBrowsablePlugin
    {
        let configuration = try NfsConnectionConfiguration(host: model.host, export: model.export)
        return try NfsBrowsablePlugin(
            id: model.id, name: model.name, configuration: configuration,
            shouldSync: model.shouldSync)
    }

    override class func loadStoredURL(_ id: String, in db: Database) throws -> String? {
        try NfsBrowsablePluginModel.fetchOne(db, key: id)
            .map { BrowsablePluginUtilities.encode($0) }
    }

    override class func deleteStoredPlugin(_ id: String, in db: Database) throws {
        _ = try NfsBrowsablePluginModel.deleteOne(db, key: id)
    }

    private var model: NfsBrowsablePluginModel {
        NfsBrowsablePluginModel(
            id: id, name: displayName, host: host, export: export, shouldSync: supports(.sync))
    }

    override func databaseModel() throws -> any PersistableRecord { model }

    override class func loadPlugins() -> [Plugin] {
        Logger.nfsBrowsablePlugin.debug("Loading NFS browsable plugins")
        guard let dbPool = DbService.shared.appDb else {
            Logger.nfsBrowsablePlugin.error("Database not available")
            return []
        }

        let models: [NfsBrowsablePluginModel]
        do { models = try dbPool.read { db in try NfsBrowsablePluginModel.fetchAll(db) } } catch {
            Logger.nfsBrowsablePlugin.error(
                "Failed to fetch NfsBrowsablePluginModels", error: error)
            return []
        }

        var results: [NfsBrowsablePlugin] = []
        for model in models {
            do {
                let configuration = try NfsConnectionConfiguration(
                    host: model.host, export: model.export)
                try results.append(
                    NfsBrowsablePlugin(
                        id: model.id, name: model.name, configuration: configuration,
                        shouldSync: model.shouldSync))
            } catch {
                Logger.nfsBrowsablePlugin.error(
                    "Failed to load NFS plugin \(model.id)", error: error)
            }
        }
        return results
    }

    override func savePlugin() throws {
        Logger.nfsBrowsablePlugin.debug("Saving NFS plugin: \(id)")
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
        }

        try db.write { db in try model.save(db) }
    }

    override func deletePlugin() throws {
        Logger.nfsBrowsablePlugin.debug("Deleting NFS plugin: \(id)")
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
        }

        _ = try db.write { db in try NfsBrowsablePluginModel.deleteOne(db, key: id) }
        try super.deletePlugin()
    }

}
