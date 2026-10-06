//
//  FsBrowsablePlugin.swift
//  mankai
//
//  Created by Travis XU on 13/7/2026.
//

import Foundation
import GRDB

struct FilesystemSession: BrowsableSession {
    typealias Config = URL

    static let backendName = "filesystem"
    static let logger = Logger.fsBrowsablePlugin

    let rootURL: URL

    init(configuration: URL) { rootURL = configuration.standardizedFileURL }

    func disconnect() async {}

    func list(path: String) async throws -> [BrowsableSessionEntry] {
        let target = try sourceURL(for: path)
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: target, includingPropertiesForKeys: Array(resourceKeys))

        return try entries.compactMap { entry in
            let values = try entry.resourceValues(forKeys: resourceKeys)
            guard values.isDirectory == true || values.isRegularFile == true else { return nil }
            return BrowsableSessionEntry(
                name: entry.lastPathComponent, isDirectory: values.isDirectory == true,
                isRegularFile: values.isRegularFile == true)
        }
    }

    func download(path: String) async throws -> Data { try Data(contentsOf: sourceURL(for: path)) }

    func upload(data: Data, path: String) async throws {
        try data.write(to: sourceURL(for: path), options: .atomic)
    }

    func upload(file: URL, path: String) async throws {
        try FileManager.default.copyItem(at: file, to: sourceURL(for: path))
    }

    func createDirectory(path: String) async throws {
        try FileManager.default.createDirectory(
            at: sourceURL(for: path), withIntermediateDirectories: true)
    }

    func localURL(for path: String?) throws -> URL? { try sourceURL(for: path) }

    func sourceURL(for relativePath: String?) throws -> URL {
        guard let relativePath, !relativePath.isEmpty else { return rootURL }

        let sourceURL = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : "\(rootURL.path)/"
        guard sourceURL.path.hasPrefix(rootPath) else {
            Logger.fsBrowsablePlugin.error("Path escapes plugin root: \(relativePath)")
            throw MankaiErrorCode.browseFilesystemInvalidMangaMeta.makeError()
        }
        return sourceURL
    }
}

class FsBrowsablePlugin: GenericBrowsablePlugin<URL, FilesystemSession> {
    override var name: String? { displayName ?? dirName }

    var url: URL { configuration }

    private var isAccessingSecurityScopedResource = false
    private lazy var dirName: String = url.lastPathComponent

    init(url: URL, id: String, name: String?, shouldSync: Bool = true) throws {
        Logger.fsBrowsablePlugin.debug("Initializing FsBrowsablePlugin with url: \(url.path)")
        try super.init(id: id, name: name, configuration: url, shouldSync: shouldSync)

        if !(self is AppDirBrowsablePlugin) {
            isAccessingSecurityScopedResource = url.startAccessingSecurityScopedResource()
            if !isAccessingSecurityScopedResource {
                Logger.fsBrowsablePlugin.error(
                    "Failed to start accessing security scoped resource for plugin: \(id)")
            }
        }
    }

    convenience init(url: URL, name: String?) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw MankaiErrorCode.browseFilesystemFailedToAccessFolder.makeError()
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let idFile = url.appendingPathComponent(".mankai")
        let id: String
        let shouldSync: Bool
        if fileManager.fileExists(atPath: idFile.path) {
            id = try String(contentsOf: idFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            shouldSync = true
        } else {
            id = UUID().uuidString
            do {
                try id.write(to: idFile, atomically: true, encoding: .utf8)
                shouldSync = true
            } catch {
                Logger.fsBrowsablePlugin.warning(
                    "Failed to write .mankai for plugin \(id), using a local-only ID: \(error)")
                shouldSync = false
            }
        }

        try self.init(url: url, id: id, name: name, shouldSync: shouldSync)
    }

    isolated deinit {
        if isAccessingSecurityScopedResource { url.stopAccessingSecurityScopedResource() }
    }

    override class func loadPlugins() -> [Plugin] {
        Logger.fsBrowsablePlugin.debug("Loading book plugins")
        guard let dbPool = DbService.shared.appDb else {
            Logger.fsBrowsablePlugin.error("Database not available")
            return []
        }

        var models: [FsBrowsablePluginModel]
        do { models = try dbPool.read { db in try FsBrowsablePluginModel.fetchAll(db) } } catch {
            Logger.fsBrowsablePlugin.error("Failed to fetch FsBrowsablePluginModels: \(error)")
            return []
        }

        var results: [FsBrowsablePlugin] = []
        for var model in models {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: model.bookmarkData, options: .withoutUI, relativeTo: nil,
                    bookmarkDataIsStale: &isStale)

                if isStale {
                    Logger.fsBrowsablePlugin.warning(
                        "Bookmark data is stale for plugin: \(model.id)")
                    let newBookmarkData = try url.bookmarkData(
                        options: .minimalBookmark, includingResourceValuesForKeys: nil,
                        relativeTo: nil)
                    model.bookmarkData = newBookmarkData
                    try dbPool.write { db in try model.update(db) }
                }

                guard url.startAccessingSecurityScopedResource() else {
                    Logger.fsBrowsablePlugin.error(
                        "Failed to start accessing security scoped resource for plugin: \(model.id)"
                    )
                    continue
                }
                defer { url.stopAccessingSecurityScopedResource() }

                try results.append(
                    FsBrowsablePlugin(
                        url: url, id: model.id, name: model.name, shouldSync: model.shouldSync))
            } catch {
                Logger.fsBrowsablePlugin.error(
                    "Failed to resolve bookmark for plugin \(model.id): \(error)")
            }
        }
        return results
    }

    override func savePlugin() throws {
        Logger.fsBrowsablePlugin.debug("Saving plugin: \(id)")
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
        }

        let bookmarkData = try url.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        try db.write { db in
            try FsBrowsablePluginModel(
                id: id, name: displayName, bookmarkData: bookmarkData, shouldSync: supports(.sync)
            )
            .save(db)
        }
    }

    override func deletePlugin() throws {
        Logger.fsBrowsablePlugin.debug("Deleting plugin: \(id)")
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
        }

        _ = try db.write { db in try FsBrowsablePluginModel.deleteOne(db, key: id) }
        try super.deletePlugin()
    }

    override func parserFile(relativePath: String, cacheKey: String) async throws -> ParserFile {
        try FsParserFile(cacheKey: cacheKey, url: session.sourceURL(for: relativePath))
    }

}
