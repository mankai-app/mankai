//
//  AppDirBrowsablePlugin.swift
//  mankai
//
//  Created by Travis XU on 13/7/2026.
//

import Foundation
import GRDB
import SwiftUI

final class AppDirBrowsablePlugin: FsBrowsablePlugin, FileDeletable {
    static let shared = try! AppDirBrowsablePlugin()

    override class func loadPlugins() -> [Plugin] { [shared] }

    private init() throws {
        let fileManager = FileManager.default
        let mangaDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!

        if !fileManager.fileExists(atPath: mangaDir.path) {
            do {
                try fileManager.createDirectory(at: mangaDir, withIntermediateDirectories: true)
            } catch {
                Logger.appDirBrowsablePlugin.error(
                    "Failed to create directory \(mangaDir.path): \(error)")
            }
        }

        let placeholderName = String(localized: "putMangaFilesHere")
        let placeholderPath = mangaDir.appendingPathComponent(placeholderName)
            .path(percentEncoded: false)
        if !fileManager.fileExists(atPath: placeholderPath),
            !fileManager.createFile(atPath: placeholderPath, contents: nil)
        {
            Logger.appDirBrowsablePlugin.error(
                "Failed to create placeholder file \(placeholderPath)")
        }

        Logger.appDirBrowsablePlugin.info(
            "AppDirBrowsablePlugin initialized with PATH: \(mangaDir.path(percentEncoded: false))")

        try super.init(url: mangaDir, id: "mankai.books", name: nil, shouldSync: false)
    }

    override var name: String? { String(localized: "localDir") }

    override var tags: [String] { super.tags + [String(localized: "builtin")] }

    override class var defaultIcon: PluginIcon { .system("iphone") }

    override class var defaultColor: Color { .accentColor }

    override var color: Color { Self.defaultColor }

    var supportedExtensions: [String] {
        Array(Set(parsers.values.flatMap(\.supportedExtensions))).sorted()
    }

    var importsEntity: Entity {
        Entity(
            path: "imports", displayName: String(localized: "imports"), name: "imports",
            type: .directory)
    }

    var downloadsEntity: Entity {
        Entity(
            path: "dowloads", displayName: String(localized: "downloads"), name: "dowloads",
            type: .directory)
    }

    var exportsEntity: Entity {
        Entity(
            path: "exports", displayName: String(localized: "exports"), name: "exports",
            type: .directory)
    }

    override func getEntities(path: String?) async throws -> [Entity] {
        let entities = try await super.getEntities(path: path)
        guard (path ?? "").isEmpty else { return entities }

        let appFolders = [importsEntity, downloadsEntity, exportsEntity]
        return entities.map { entity in
            guard entity.type == .directory else { return entity }
            return appFolders.first(where: { $0.path == entity.path }) ?? entity
        }
    }

    /// Copies a supported file into the app's imports folder without replacing existing files.
    func importFile(from source: URL) async throws {
        let needsScopeAccess = source.startAccessingSecurityScopedResource()
        defer { if needsScopeAccess { source.stopAccessingSecurityScopedResource() } }

        guard parser(forExtension: source.pathExtension.lowercased()) != nil else {
            throw MankaiErrorCode.browseFilesystemParserNotFound.makeError()
        }
        guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw MankaiErrorCode.browseFilesystemInvalidMangaMeta.makeError()
        }

        try await copyFile(from: source, into: importsEntity.path)
    }

    func saveExport(from source: URL) async throws {
        // The browser skips dotfiles.
        let name = source.lastPathComponent
        try await copyFile(
            from: source, into: exportsEntity.path, named: name.hasPrefix(".") ? "_\(name)" : name)
    }

    func saveDownload(from source: URL, named fileName: String) async throws -> URL {
        let originalName = fileName as NSString
        let fileExtension = originalName.pathExtension
        let sanitizedName =
            fileExtension.isEmpty
            ? FileUtilities.sanitizedStem(fileName)
            : FileUtilities.filename(
                for: originalName.deletingPathExtension, fileExtension: fileExtension)

        return try await copyFile(from: source, into: downloadsEntity.path, named: sanitizedName)
    }

    @discardableResult private func copyFile(
        from source: URL, into path: String, named name: String? = nil
    ) async throws -> URL {
        try Task.checkCancellation()

        let directory = try session.sourceURL(for: path)
        let temporaryURL = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let copyTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: temporaryURL)
        }
        try await withTaskCancellationHandler {
            try await copyTask.value
        } onCancel: {
            copyTask.cancel()
        }
        try Task.checkCancellation()

        let proposedURL = directory.appendingPathComponent(
            name ?? source.lastPathComponent, isDirectory: false)
        var existingNames = Set(try fileManager.contentsOfDirectory(atPath: directory.path))

        while true {
            let fileName = FileUtilities.uniqueFileName(
                for: proposedURL, existingNames: existingNames)
            let destination = directory.appendingPathComponent(fileName, isDirectory: false)
            do {
                try fileManager.moveItem(at: temporaryURL, to: destination)
                objectWillChange.send()
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                existingNames.insert(fileName)
            }
        }
    }

    func deleteFile(path: String) async throws {
        guard !path.isEmpty else {
            throw MankaiErrorCode.browseFilesystemInvalidMangaMeta.makeError()
        }

        let fileURL = try session.sourceURL(for: path)
        let rootPath = url.resolvingSymlinksInPath().path(percentEncoded: false)
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard fileURL.resolvingSymlinksInPath().path(percentEncoded: false).hasPrefix(rootPrefix),
            resourceValues.isRegularFile == true
        else { throw MankaiErrorCode.browseFilesystemInvalidMangaMeta.makeError() }

        try FileManager.default.removeItem(at: fileURL)
        defer { objectWillChange.send() }
        try invalidateCachedManga(path: path)
    }

    /// Built-in plugin, do nothing
    override func savePlugin(db: Database? = nil) throws {}

    /// Built-in plugin, do nothing
    override func deletePlugin() throws {}
}
