//
//  DowloadPlugin.swift
//  mankai
//
//  Created by Travis XU on 13/2/2026.
//

import Foundation
import GRDB
import ImageIO

final class DownloadPlugin: Plugin {
    static let shared = DownloadPlugin()

    override var id: String { "download" }

    override var name: String? { "Downloaded" }

    override class var typeCapabilities: [PluginTypeCapability] { [] }

    override var capabilities: [PluginCapability] {
        [.onlineCheck, .mangaDetails, .chapter, .image]
    }

    let downloadDir: URL
    var db: DatabasePool? { DbService.shared.openDownloadDb() }

    override private init() {
        Logger.downloadPlugin.debug("Initializing DownloadPlugin")

        let fileManager = FileManager.default
        downloadDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("downloads")

        if !fileManager.fileExists(atPath: downloadDir.path) {
            do {
                try fileManager.createDirectory(at: downloadDir, withIntermediateDirectories: true)
            } catch { Logger.downloadPlugin.error("Failed to create download directory: \(error)") }
        }
    }

    /// Built-in plugin, do nothing
    override func savePlugin(db: Database? = nil) throws {}

    /// Built-in plugin, do nothing
    override func deletePlugin() throws {}

    override func isOnline() async throws -> Bool { return true }

    // MARK: - Helper Functions

    nonisolated private static func convertToDetailedManga(
        _ model: DownloadMangaModel, db: Database
    ) throws -> DetailedManga {
        var manga = model.sourceSnapshot
        let groups = model.chapters
        let chapters = try DownloadChapterModel.filter(Column("mangaId") == model.id).fetchAll(db)

        let completed = Set(chapters.filter(\.completed).map(\.chapterId))
        manga.chapters = groups.map { group in
            var group = group
            group.chapters = group.chapters.map { chapter in
                var chapter = chapter
                chapter.locked = !completed.contains(chapter.id)

                return chapter
            }

            return group
        }

        manga.meta = model.pluginId

        let cover =
            try DownloadImageModel.filter(
                Column("mangaId") == model.id && Column("chapterId") == nil
                    && Column("url") == model.cover && Column("completed") == true
            )
            .fetchOne(db)
        manga.cover = cover?.reference

        return manga
    }

    // MARK: - Override Methods

    override func getDetailedManga(_ id: String) async throws -> DetailedManga {
        Logger.downloadPlugin.debug("Getting detailed manga: \(id)")
        guard let db = db else {
            Logger.downloadPlugin.error("Database not available for getDetailedManga")
            throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError()
        }

        return try await db.read { db in
            guard let mangaModel = try DownloadMangaModel.fetchOne(db, key: id) else {
                Logger.downloadPlugin.warning("Manga not found in DB: \(id)")
                throw MankaiErrorCode.pluginDownloadMangaNotFound.makeError()
            }

            return try Self.convertToDetailedManga(mangaModel, db: db)
        }
    }

    override func getChapter(manga: DetailedManga, chapter: Chapter) async throws -> [String] {
        guard let db else { throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError() }

        guard let pluginId = manga.meta else {
            throw MankaiErrorCode.pluginDownloadMangaMetaMissing.makeError()
        }

        let mangaId = DownloadMangaModel.makeId(pluginId: pluginId, mangaId: manga.id)

        return try await db.read { db in
            guard
                let record =
                    try DownloadChapterModel.filter(
                        Column("mangaId") == mangaId && Column("chapterId") == chapter.id
                    )
                    .fetchOne(db), record.completed
            else { throw MankaiErrorCode.pluginDownloadChapterNotFound.makeError() }

            let images = try DownloadImageModel.filter(Column("chapterId") == record.id)
                .order(Column("pageIndex")).fetchAll(db)

            guard !images.isEmpty, images.allSatisfy(\.completed) else {
                throw MankaiErrorCode.pluginDownloadChapterNotFound.makeError()
            }

            return images.map(\.reference)
        }
    }

    override func getImage(_ path: String) async throws -> Data {
        guard let db else { throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError() }

        guard let reference = URL(string: path), reference.scheme == "mankai-download",
            reference.host == "image"
        else { throw MankaiErrorCode.pluginDownloadFailedToLoadImage.makeError() }

        let id = reference.deletingPathExtension().lastPathComponent

        guard let image = try await db.read({ try DownloadImageModel.fetchOne($0, key: id) }),
            image.completed
        else { throw MankaiErrorCode.pluginDownloadFailedToLoadImage.makeError() }

        let file = downloadDir.appendingPathComponent(image.path)
        return
            try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)

                guard Self.isValidImage(data) else {
                    throw MankaiErrorCode.pluginDownloadFailedToLoadImage.makeError()
                }

                return data
            }
            .value
    }

    func getCover(_ url: String, pluginId: String) async throws -> Data {
        guard let db else { throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError() }

        let image = try await db.read { db in
            try DownloadImageModel.filter(
                sql:
                    "chapterId IS NULL AND url = ? AND completed = 1 AND mangaId IN (SELECT id FROM manga WHERE pluginId = ?)",
                arguments: [url, pluginId]
            )
            .fetchOne(db)
        }

        guard let image else { throw MankaiErrorCode.pluginDownloadFailedToLoadImage.makeError() }

        return try await getImage(image.reference)
    }

    func getSavedMangas() async throws -> [DetailedManga] {
        guard let db else { throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError() }

        return try await db.read { db in
            try DownloadMangaModel.fetchAll(db).map { try Self.convertToDetailedManga($0, db: db) }
                .sorted {
                    ($0.title ?? $0.id).localizedStandardCompare($1.title ?? $1.id)
                        == .orderedAscending
                }
        }
    }

    func getDownloadedMangas() async throws -> [DetailedManga] {
        guard let db else { throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError() }

        return try await db.read { db in
            let mangas =
                try DownloadMangaModel.filter(
                    sql:
                        "EXISTS (SELECT 1 FROM chapter WHERE chapter.mangaId = manga.id AND chapter.completed = 1)"
                )
                .fetchAll(db)

            return try mangas.map { try Self.convertToDetailedManga($0, db: db) }
        }
    }

    func saveImage(_ image: DownloadImageModel, data: Data) async throws {
        guard let db else { throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError() }

        let file = downloadDir.appendingPathComponent(image.path)

        try await Task.detached(priority: .utility) {
            guard Self.isValidImage(data) else {
                throw MankaiErrorCode.downloadInvalidImage.makeError()
            }

            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)

            var completed = image
            completed.completed = true
            try await db.write { [completed] in try completed.update($0) }
        }
        .value
    }

    nonisolated private static func isValidImage(_ data: Data) -> Bool {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { return false }

        return true
    }

    func deleteManga(_ mangaId: String) throws -> [DownloadImageModel] {
        guard let db else { throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError() }

        return try db.write { db in
            let images = try DownloadImageModel.filter(Column("mangaId") == mangaId).fetchAll(db)
            _ = try DownloadMangaModel.deleteOne(db, key: mangaId)

            return images
        }
    }

    func deleteImages(_ images: [DownloadImageModel]) async throws {
        let directory = downloadDir

        try await Task.detached(priority: .utility) {
            for image in images {
                do {
                    try FileManager.default.removeItem(
                        at: directory.appendingPathComponent(image.path))
                } catch {
                    let error = error as NSError

                    if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                        continue
                    }
                    throw error
                }
            }
        }
        .value
    }
}
