//
//  WebDavBrowsablePlugin.swift
//  mankai
//
//  Created by Travis XU on 10/8/2026.
//

import Foundation
import GRDB
import SwiftUI
import WebDAV

struct WebDavConnectionConfiguration: Sendable {
    let baseURL: URL
    var username: String?
    var password: String?

    init(baseURL: String, username: String? = nil, password: String? = nil) throws {
        guard let normalizedURL = URL.normalizedHTTPURL(baseURL, ensuresTrailingSlash: true) else {
            throw MankaiErrorCode.browseWebDavInvalidConnectionConfiguration.makeError()
        }

        self.baseURL = normalizedURL
        self.username = username.trimmed
        self.password = password.trimmed
    }
}

private struct MankaiWebDavAccount: WebDAVAccount, Sendable {
    let username: String?
    let baseURL: String?
}

/// Serializes access to the callback-based WebDAV client.
actor WebDavSession: BrowsableSession {
    typealias Config = WebDavConnectionConfiguration

    static let backendName = "WebDAV"
    static let logger = Logger.webDavBrowsablePlugin

    nonisolated let configuration: WebDavConnectionConfiguration

    private let client = WebDAV()
    private let account: MankaiWebDavAccount

    init(configuration: WebDavConnectionConfiguration) {
        self.configuration = configuration
        account = MankaiWebDavAccount(
            username: configuration.username ?? "", baseURL: configuration.baseURL.absoluteString)
    }

    func disconnect() async {}

    func list(path: String) async throws -> [BrowsableSessionEntry] {
        try await withCheckedThrowingContinuation { continuation in
            client.listFiles(
                atPath: path, account: account, password: configuration.password ?? "",
                caching: .disableCache
            ) { files, error in
                if let error {
                    continuation.resume(throwing: Self.requestError(error))
                } else if let files {
                    let entries = files.map { file in
                        BrowsableSessionEntry(
                            name: file.fileName, isDirectory: file.isDirectory,
                            isRegularFile: !file.isDirectory)
                    }
                    continuation.resume(returning: entries)
                } else {
                    continuation.resume(
                        throwing: MankaiErrorCode.browseWebDavRequestFailed.makeError())
                }
            }
        }
    }

    func download(path: String) async throws -> Data {
        let data: Data? = try await withCheckedThrowingContinuation { continuation in
            client.download(
                fileAtPath: path, account: account, password: configuration.password ?? "",
                caching: .disableCache
            ) { data, error in
                if let error {
                    continuation.resume(throwing: Self.requestError(error))
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
        guard let data else { throw MankaiErrorCode.browseFilesystemEntryNotFound.makeError() }
        return data
    }

    func createDirectory(path: String) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            client.createFolder(
                atPath: path, account: account, password: configuration.password ?? ""
            ) { error in
                if let error {
                    continuation.resume(throwing: Self.requestError(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func upload(data: Data, path: String) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            client.upload(
                data: data, toPath: path, account: account, password: configuration.password ?? ""
            ) { error in
                if let error {
                    continuation.resume(throwing: Self.requestError(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func upload(file: URL, path: String) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            client.upload(
                file: file, toPath: path, account: account, password: configuration.password ?? ""
            ) { error in
                if let error {
                    continuation.resume(throwing: Self.requestError(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private nonisolated static func requestError(_ error: WebDAVError) -> Error {
        MankaiErrorCode.browseWebDavRequestFailed.makeError(underlyingError: error)
    }
}

final class WebDavBrowsablePlugin: GenericBrowsablePlugin<
    WebDavConnectionConfiguration, WebDavSession
>
{

    /// Creates a new WebDAV plugin after validating the connection and resolving its identity.
    convenience init(session: WebDavSession, name: String?) async throws {
        do {
            let identity = try await BrowsablePluginUtilities.resolveIdentity(
                using: session,
                invalidPluginError: MankaiErrorCode.browseWebDavInvalidPlugin.makeError())

            try self.init(
                id: identity.id, name: name, configuration: session.configuration, session: session,
                shouldSync: identity.shouldSync)
        } catch {
            Logger.webDavBrowsablePlugin.error(
                "Failed to create WebDAV browsable plugin for \(session.configuration.baseURL.absoluteString)",
                error: error)
            throw error
        }
    }

    init(
        id: String, name: String?, configuration: WebDavConnectionConfiguration,
        session: WebDavSession? = nil, shouldSync: Bool = true
    ) throws {
        try super
            .init(
                id: id, name: name, configuration: configuration, session: session,
                temporaryDirectoryName: "webdav", shouldSync: shouldSync)
    }

    var baseURL: URL { configuration.baseURL }

    var username: String? { configuration.username }

    var password: String? { configuration.password }

    override var name: String? {
        if let displayName { return displayName }

        let host = baseURL.host ?? baseURL.absoluteString
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : "\(host)/\(path)"
    }

    override var tags: [String] { ["WebDAV"] }

    override var icon: AnyView { AnyView(LabeledFolderIcon(label: "DAV", color: color)) }

    override class var syncType: String? { "webdav" }

    override class var typeCapabilities: [PluginTypeCapability] { [.urlDecoding] }

    override func encodeURL() -> String { BrowsablePluginUtilities.encode(model) }

    override class func decodeURL(_ url: String, sourceId: String? = nil) async -> Plugin? {
        guard var model: WebDavBrowsablePluginModel = BrowsablePluginUtilities.decode(url) else {
            return nil
        }
        if let sourceId { model.id = sourceId }
        return try? fromDataModel(model)
    }

    private static func fromDataModel(_ model: WebDavBrowsablePluginModel) throws
        -> WebDavBrowsablePlugin
    {
        let configuration = try WebDavConnectionConfiguration(
            baseURL: model.baseURL, username: model.username, password: model.password)
        return try WebDavBrowsablePlugin(
            id: model.id, name: model.name, configuration: configuration,
            shouldSync: model.shouldSync)
    }

    override class func loadStoredURL(_ id: String, in db: Database) throws -> String? {
        try WebDavBrowsablePluginModel.fetchOne(db, key: id)
            .map { BrowsablePluginUtilities.encode($0) }
    }

    override class func deleteStoredPlugin(_ id: String, in db: Database) throws {
        _ = try WebDavBrowsablePluginModel.deleteOne(db, key: id)
    }

    private var model: WebDavBrowsablePluginModel {
        WebDavBrowsablePluginModel(
            id: id, name: displayName, baseURL: baseURL.absoluteString, username: username,
            password: password, shouldSync: supports(.sync))
    }

    override class func loadPlugins() -> [Plugin] {
        Logger.webDavBrowsablePlugin.debug("Loading WebDAV browsable plugins")
        guard let dbPool = DbService.shared.appDb else {
            Logger.webDavBrowsablePlugin.error("Database not available")
            return []
        }

        let models: [WebDavBrowsablePluginModel]
        do { models = try dbPool.read { db in try WebDavBrowsablePluginModel.fetchAll(db) } } catch
        {
            Logger.webDavBrowsablePlugin.error(
                "Failed to fetch WebDavBrowsablePluginModels", error: error)
            return []
        }

        var results: [WebDavBrowsablePlugin] = []
        for model in models {
            do {
                let configuration = try WebDavConnectionConfiguration(
                    baseURL: model.baseURL, username: model.username, password: model.password)
                try results.append(
                    WebDavBrowsablePlugin(
                        id: model.id, name: model.name, configuration: configuration,
                        shouldSync: model.shouldSync))
            } catch {
                Logger.webDavBrowsablePlugin.error(
                    "Failed to load WebDAV plugin \(model.id)", error: error)
            }
        }
        return results
    }

    override func savePlugin(db: Database? = nil) throws {
        Logger.webDavBrowsablePlugin.debug("Saving WebDAV plugin: \(id)")
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
        Logger.webDavBrowsablePlugin.debug("Deleting WebDAV plugin: \(id)")
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
        }

        _ = try db.write { db in try WebDavBrowsablePluginModel.deleteOne(db, key: id) }
        try super.deletePlugin()
    }

}
