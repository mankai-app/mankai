//
//  DowloadPlugin.swift
//  mankai
//
//  Created by Travis XU on 13/2/2026.
//

import Foundation
import GRDB

enum DownloadPluginConstants {
    /// Maximum number of search/list results per page
    static let pageLimit: UInt = 25

    /// Maximum number of suggestions to return
    static let suggestionLimit: UInt = 5
}

final class DownloadPlugin: Plugin {
    static let shared = DownloadPlugin()

    override var id: String { "download" }

    override var name: String? { "Downloaded" }

    override var shouldSync: Bool { false }

    override var availableGenres: [Genre] { Genre.allCases }

    let downloadDir: URL
    var db: DatabasePool? { DbService.shared.openDownloadDb() }

    override private init() {
        Logger.downloadPlugin.debug("Initializing DownloadPlugin")

        let fileManager = FileManager.default
        downloadDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("downloads")

        if !fileManager.fileExists(atPath: downloadDir.path) {
            try! fileManager.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        }
    }

    /// Built-in plugin, do nothing
    override func savePlugin() throws {}

    /// Built-in plugin, do nothing
    override func deletePlugin() throws {}

    override func isOnline() async throws -> Bool { return true }

    // MARK: - Helper Functions

    nonisolated private static func convertToManga(_ mangaModel: DownloadMangaModel) -> Manga? {
        return convertToDetailedManga(mangaModel)?.toManga()
    }

    nonisolated private static func convertToDetailedManga(
        _ mangaModel: DownloadMangaModel, db: Database? = nil
    ) -> DetailedManga? {
        var mangaDict: [String: Any] = ["id": mangaModel.mangaId]

        if let title = mangaModel.title { mangaDict["title"] = title }

        if let cover = mangaModel.cover { mangaDict["cover"] = cover }

        if let status = mangaModel.status { mangaDict["status"] = UInt(status) }

        if let description = mangaModel.description { mangaDict["description"] = description }

        if let updatedAt = mangaModel.updatedAt {
            mangaDict["updatedAt"] = Int64(updatedAt.timeIntervalSince1970 * 1000)
        }

        let authors = mangaModel.authors.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        mangaDict["authors"] = authors

        let genres = mangaModel.genres.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        mangaDict["genres"] = genres

        if let latestChapter = mangaModel.latestChapter,
            let chapterData = latestChapter.data(using: .utf8),
            let chapterDict = try? JSONSerialization.jsonObject(with: chapterData) as? [String: Any]
        {
            mangaDict["latestChapter"] = chapterDict
        }

        if let chapters = mangaModel.chapters, let chaptersData = chapters.data(using: .utf8),
            let chapterGroups = try? JSONSerialization.jsonObject(with: chaptersData)
        {
            mangaDict["chapters"] = chapterGroups
        }

        mangaDict["meta"] = mangaModel.pluginId

        guard var detailedManga = DetailedManga(from: mangaDict) else { return nil }

        if let db = db {
            do {
                let chapters = try DownloadChapterModel.filter(Column("mangaId") == mangaModel.id)
                    .fetchAll(db)

                let downloadedChapterIds = Set(
                    chapters.filter { $0.downloaded }.map { $0.chapterId })

                detailedManga.chapters = detailedManga.chapters.map { group in
                    var updatedGroup = group
                    updatedGroup.chapters = group.chapters.map { chapter in
                        var newChapter = chapter
                        if !downloadedChapterIds.contains(chapter.id) { newChapter.locked = true }
                        return newChapter
                    }
                    return updatedGroup
                }
            } catch {
                Logger.downloadPlugin.error(
                    "Failed to fetch chapters for download status check: \(error)")
            }
        }

        return detailedManga
    }

    // MARK: - Override Methods

    override func getSuggestions(_ query: String) async throws -> [String] {
        Logger.downloadPlugin.debug("Getting suggestions for query: \(query)")
        guard let db = db else {
            Logger.downloadPlugin.error("Database not available for suggestions")
            throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError()
        }

        return try await db.read { db in
            let searchQuery = "%\(query.lowercased())%"
            let mangas =
                try DownloadMangaModel.filter(sql: "LOWER(title) LIKE ?", arguments: [searchQuery])
                .limit(Int(DownloadPluginConstants.suggestionLimit)).fetchAll(db)

            return mangas.compactMap { $0.title }
        }
    }

    override func search(_ query: String, page: UInt, genre: Genre, status: Status, isAuthor: Bool)
        async throws -> [Manga]
    {
        Logger.downloadPlugin.debug(
            "Searching for: \(query), page: \(page), genre: \(genre), status: \(status), isAuthor: \(isAuthor)"
        )
        guard let db = db else {
            Logger.downloadPlugin.error("Database not available for search")
            throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError()
        }

        return try await db.read { db in
            let searchQuery = "%\(query.lowercased())%"
            let offset = Int((page - 1) * DownloadPluginConstants.pageLimit)
            let limit = Int(DownloadPluginConstants.pageLimit)

            let searchColumn = isAuthor ? "authors" : "title"
            var query = DownloadMangaModel.filter(
                sql: "LOWER(\(searchColumn)) LIKE ?", arguments: [searchQuery])

            // Filter by genre if not "all"
            if genre != .all {
                let genreQuery = "%\(genre.rawValue.lowercased())%"
                query = query.filter(sql: "LOWER(genres) LIKE ?", arguments: [genreQuery])
            }

            // Filter by status if not "any"
            if status != .any { query = query.filter(Column("status") == Int(status.rawValue)) }

            let mangas = try query.limit(limit, offset: offset).fetchAll(db)

            return mangas.compactMap(Self.convertToManga)
        }
    }

    override func getList(page: UInt, genre: Genre, status: Status) async throws -> [Manga] {
        Logger.downloadPlugin.debug(
            "Getting list, page: \(page), genre: \(genre), status: \(status)")
        guard let db = db else {
            Logger.downloadPlugin.error("Database not available for list")
            throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError()
        }

        return try await db.read { db in
            let offset = Int((page - 1) * DownloadPluginConstants.pageLimit)
            let limit = Int(DownloadPluginConstants.pageLimit)

            var query = DownloadMangaModel.all()

            // Filter by genre if not "all"
            if genre != .all {
                let genreQuery = "%\(genre.rawValue)%"
                query = query.filter(sql: "LOWER(genres) LIKE ?", arguments: [genreQuery])
            }

            // Filter by status if not "any"
            if status != .any { query = query.filter(Column("status") == Int(status.rawValue)) }

            let mangas = try query.limit(limit, offset: offset).fetchAll(db)

            return mangas.compactMap(Self.convertToManga)
        }
    }

    override func getMangas(_ ids: [String]) async throws -> [Manga] {
        Logger.downloadPlugin.debug("Getting \(ids.count) mangas")
        guard let db = db else {
            Logger.downloadPlugin.error("Database not available for getMangas")
            throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError()
        }

        return try await db.read { db in
            let mangas = try DownloadMangaModel.filter(ids.contains(Column("id"))).fetchAll(db)

            return mangas.compactMap(Self.convertToManga)
        }
    }

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

            guard let detailedManga = Self.convertToDetailedManga(mangaModel, db: db) else {
                Logger.downloadPlugin.error(
                    "Failed to convert manga model to detailed manga: \(id)")
                throw MankaiErrorCode.pluginDownloadFailedToLoadMangaDetails.makeError()
            }

            return detailedManga
        }
    }

    override func getChapter(manga: DetailedManga, chapter: Chapter) async throws -> [String] {
        Logger.downloadPlugin.debug("Getting chapter: \(chapter.id)")
        guard let db = db else {
            Logger.downloadPlugin.error("Database not available for getChapter")
            throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError()
        }

        guard let pluginId = manga.meta else {
            Logger.downloadPlugin.error("Manga meta is missing for getChapter: \(manga.id)")
            throw MankaiErrorCode.pluginDownloadMangaMetaMissing.makeError()
        }

        let mangaId = "\(pluginId)+\(manga.id)"

        return try await db.read { db in
            guard
                let chapterModel =
                    try DownloadChapterModel.filter(
                        Column("mangaId") == mangaId && Column("chapterId") == chapter.id
                    )
                    .fetchOne(db)
            else {
                Logger.downloadPlugin.error("Chapter not found: \(chapter.id)")
                throw MankaiErrorCode.pluginDownloadChapterNotFound.makeError()
            }

            return chapterModel.urls.split(separator: "|").map { String($0) }
        }
    }

    override func getImage(_ path: String) async throws -> Data {
        Logger.downloadPlugin.debug("Getting image: \(path)")
        guard let db = db else {
            Logger.downloadPlugin.error("Database not available for getImage")
            throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError()
        }

        return try await db.read { db in
            // First try to get the image from the database
            guard let imageModel = try DownloadImageModel.filter(Column("url") == path).fetchOne(db)
            else {
                Logger.downloadPlugin.error("Image not found in DB: \(path)")
                throw MankaiErrorCode.pluginDownloadFailedToLoadImage.makeError()
            }

            let fileManager = FileManager.default
            let fullImagePath = downloadDir.appendingPathComponent(imageModel.path).path

            guard fileManager.fileExists(atPath: fullImagePath) else {
                Logger.downloadPlugin.error("Image file not found: \(fullImagePath)")
                throw MankaiErrorCode.pluginDownloadFailedToLoadImage.makeError()
            }

            do { return try Data(contentsOf: URL(fileURLWithPath: fullImagePath)) } catch {
                Logger.downloadPlugin.error(
                    "Failed to load image data: \(fullImagePath)", error: error)
                throw MankaiErrorCode.pluginDownloadFailedToLoadImage.makeError(
                    underlyingError: error)
            }
        }
    }

    // MARK: - Save Functions

    func getDownloadedMangas() async throws -> [DetailedManga] {
        Logger.downloadPlugin.debug("Getting downloaded mangas")
        guard let db = db else {
            Logger.downloadPlugin.error("Database not available for getDownloadedMangas")
            throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError()
        }

        return try await db.read { db in
            let mangas = try DownloadMangaModel.filter(Column("downloaded") == true).fetchAll(db)

            return mangas.compactMap { mangaModel in Self.convertToDetailedManga(mangaModel, db: db)
            }
        }
    }

    func isImageDownloaded(_ url: String) async throws -> Bool {
        guard let db = db else {
            Logger.downloadPlugin.error("Database not available for saveImage")
            throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError()
        }

        return try await db.read { db in
            try DownloadImageModel.filter(Column("url") == url).fetchOne(db) != nil
        }
    }

    func saveImage(url: String, data: Data, mangaId: String) async throws {
        Logger.downloadPlugin.debug("Saving image: \(url)")

        // Check if image already exists
        if try await isImageDownloaded(url) {
            Logger.downloadPlugin.info("Image already downloaded: \(url)")
            return
        }

        let fileManager = FileManager.default
        let imagesDir = downloadDir.appendingPathComponent("images/\(mangaId)")

        if !fileManager.fileExists(atPath: imagesDir.path) {
            try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        }

        // Generate filename
        let ext = URL(string: url)?.pathExtension ?? "jpg"
        let filename = "\(UUID().uuidString).\(ext)"
        let path = "images/\(mangaId)/\(filename)"
        let fullPath = downloadDir.appendingPathComponent(path)

        // Save file
        try data.write(to: fullPath)

        // Save to DB
        let imageModel = DownloadImageModel(url: url, mangaId: mangaId, path: path)

        try await saveImage(imageModel)
    }

    func saveManga(_ manga: DownloadMangaModel) async throws {
        Logger.downloadPlugin.debug("Saving manga: \(manga.title ?? manga.id)")
        guard let db = db else {
            Logger.downloadPlugin.error("Database not available for saveManga")
            throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError()
        }

        try await db.write { db in try manga.save(db) }

        objectWillChange.send()
    }

    func saveChapter(_ chapter: DownloadChapterModel) async throws {
        Logger.downloadPlugin.debug("Saving chapter: \(chapter.chapterId)")
        guard let db = db else {
            Logger.downloadPlugin.error("Database not available for saveChapter")
            throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError()
        }

        try await db.write { db in try chapter.save(db) }

        objectWillChange.send()
    }

    func saveImage(_ image: DownloadImageModel) async throws {
        Logger.downloadPlugin.debug("Saving image: \(image.url)")
        guard let db = db else {
            Logger.downloadPlugin.error("Database not available for saveImage")
            throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError()
        }

        try await db.write { db in try image.save(db) }
    }

    /// Deletes a manga from the database and removes its image directory from disk
    /// - Parameter mangaId: The ID of the manga to delete
    /// - Note: Related chapters and images will be automatically deleted from the database due to cascade constraints
    func deleteManga(_ mangaId: String) async throws {
        Logger.downloadPlugin.debug("Deleting manga: \(mangaId)")
        guard let db = db else {
            Logger.downloadPlugin.error("Database not available for deleteManga")
            throw MankaiErrorCode.pluginDownloadDatabaseNotAvailable.makeError()
        }

        let fileManager = FileManager.default

        // Delete the manga's image directory from disk
        let imagesDir = downloadDir.appendingPathComponent("images/\(mangaId)")
        if fileManager.fileExists(atPath: imagesDir.path) {
            do {
                try fileManager.removeItem(at: imagesDir)
                Logger.downloadPlugin.debug("Deleted manga image directory: \(imagesDir.path)")
            } catch {
                Logger.downloadPlugin.warning(
                    "Failed to delete manga image directory: \(imagesDir.path) - \(error.localizedDescription)"
                )
            }
        }

        // Delete the manga from the database
        try await db.write { db in
            guard let mangaModel = try DownloadMangaModel.fetchOne(db, key: mangaId) else {
                Logger.downloadPlugin.warning("Manga not found in database: \(mangaId)")
                throw MankaiErrorCode.pluginDownloadMangaNotFound.makeError()
            }

            try mangaModel.delete(db)
            Logger.downloadPlugin.debug("Successfully deleted manga from database: \(mangaId)")
        }

        objectWillChange.send()
    }

    func deleteManga(_ manga: DetailedManga) async throws {
        guard let pluginId = manga.meta else {
            Logger.downloadPlugin.error("Manga meta is missing for deleteManga: \(manga.id)")
            throw MankaiErrorCode.pluginDownloadMangaMetaMissing.makeError()
        }

        try await deleteManga("\(pluginId)+\(manga.id)")
    }
}
