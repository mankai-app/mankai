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

    /// Copies a supported file into the app's imports folder without replacing existing files.
    func importFile(from source: URL) throws {
        let needsScopeAccess = source.startAccessingSecurityScopedResource()
        defer { if needsScopeAccess { source.stopAccessingSecurityScopedResource() } }

        guard parser(forExtension: source.pathExtension.lowercased()) != nil else {
            throw MankaiErrorCode.browseFilesystemParserNotFound.makeError()
        }
        guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw MankaiErrorCode.browseFilesystemInvalidMangaMeta.makeError()
        }

        let fileManager = FileManager.default
        let importsURL = try session.sourceURL(for: importsEntity.path)
        try fileManager.createDirectory(at: importsURL, withIntermediateDirectories: true)
        let existingNames = try fileManager.contentsOfDirectory(atPath: importsURL.path)
        let fileName = FileUtilities.uniqueFileName(for: source, existingNames: Set(existingNames))
        try fileManager.copyItem(at: source, to: importsURL.appendingPathComponent(fileName))
        objectWillChange.send()
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
