//
//  ReadFsPlugin.swift
//  mankai
//
//  Created by Travis XU on 2/7/2025.
//

import CryptoKit
import Foundation
import GRDB

enum ReadFsPluginConstants {
    /// Maximum number of search/list results per page
    static let pageLimit: UInt = 25

    /// Maximum number of suggestions to return
    static let suggestionLimit: UInt = 5
}

class ReadFsPlugin: Plugin {
    let url: URL

    // MARK: - Cache

    private lazy var dirName: String = url.lastPathComponent
    lazy var _dbPath: String = url.appendingPathComponent("data.db").path(percentEncoded: false)
    private let _id: String
    private let _shouldSync: Bool
    private var _isAccessing: Bool = false

    private lazy var _db: DatabasePool? = DbService.shared.openFsDb(_dbPath, readOnly: true)
    var db: DatabasePool? { _db }

    init(url: URL, id: String, shouldSync: Bool = true) {
        Logger.fsPlugin.debug("Initializing ReadFsPlugin with url: \(url.path)")
        self.url = url
        _id = id
        _shouldSync = shouldSync

        super.init()

        if !(self is AppDirPlugin) {
            _isAccessing = url.startAccessingSecurityScopedResource()
            if !_isAccessing {
                Logger.fsPlugin.error(
                    "Failed to start accessing security scoped resource for plugin: \(_id)")
            }
        }
    }

    convenience init(url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw MankaiErrorCode.pluginFilesystemFailedToAccessFolder.makeError()
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let identity = try Self.resolveIdentity(at: url)
        self.init(url: url, id: identity.id, shouldSync: identity.shouldSync)
    }

    static func resolveIdentity(at url: URL) throws -> (id: String, shouldSync: Bool) {
        let idFile = url.appendingPathComponent(".mankai")
        if FileManager.default.fileExists(atPath: idFile.path) {
            let id = try String(contentsOf: idFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw MankaiErrorCode.pluginFilesystemPluginIdEmpty.makeError()
            }
            return (id, true)
        }

        let id = UUID().uuidString
        do {
            try id.write(to: idFile, atomically: true, encoding: .utf8)
            return (id, true)
        } catch {
            Logger.fsPlugin.warning(
                "Failed to write .mankai for plugin \(id), using a local-only ID: \(error)")
            return (id, false)
        }
    }

    isolated deinit { if _isAccessing { url.stopAccessingSecurityScopedResource() } }

    override class func loadPlugins() -> [Plugin] {
        Logger.fsPlugin.debug("Loading FS plugins")
        guard let dbPool = DbService.shared.appDb else {
            Logger.fsPlugin.error("Database not available")
            return []
        }

        var results: [ReadFsPlugin] = []

        var models: [FsPluginModel] = []
        do { try dbPool.read { db in models = try FsPluginModel.fetchAll(db) } } catch {
            Logger.fsPlugin.error("Failed to fetch FsPluginModels: \(error)")
            return []
        }

        for var model in models {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: model.bookmarkData, options: .withoutUI, relativeTo: nil,
                    bookmarkDataIsStale: &isStale)

                if isStale {
                    Logger.fsPlugin.warning("Bookmark data is stale for plugin: \(model.id)")
                    do {
                        let newBookmarkData = try url.bookmarkData(
                            options: .minimalBookmark, includingResourceValuesForKeys: nil,
                            relativeTo: nil)
                        model.bookmarkData = newBookmarkData
                        try dbPool.write { db in try model.update(db) }
                        Logger.fsPlugin.info("Updated stale bookmark for plugin: \(model.id)")
                    } catch {
                        Logger.fsPlugin.error(
                            "Failed to update stale bookmark for plugin \(model.id): \(error)")
                        continue
                    }
                }

                if !url.startAccessingSecurityScopedResource() {
                    Logger.fsPlugin.error(
                        "Failed to start accessing security scoped resource for plugin: \(model.id)"
                    )
                    continue
                }

                defer { url.stopAccessingSecurityScopedResource() }

                let plugin: ReadFsPlugin

                if model.isWriteable {
                    plugin = ReadWriteFsPlugin(url: url, id: model.id, shouldSync: model.shouldSync)
                } else {
                    plugin = ReadFsPlugin(url: url, id: model.id, shouldSync: model.shouldSync)
                }

                results.append(plugin)
            } catch {
                Logger.fsPlugin.error("Failed to resolve bookmark for plugin \(model.id): \(error)")
            }
        }

        return results
    }

    // MARK: - Metadata

    override var id: String { _id }

    override var capabilities: [PluginCapability] {
        _shouldSync ? super.capabilities : super.capabilities.filter { $0 != .sync }
    }

    override var tags: [String] { [String(localized: "fs")] }

    override var name: String? { dirName }

    override var availableGenres: [Genre] { Genre.allCases }

    override class var typeCapabilities: [PluginTypeCapability] { [] }

    // MARK: - Override Methods

    override func savePlugin(db: Database? = nil) throws {
        Logger.fsPlugin.debug("Saving plugin: \(id)")
        let bookmarkData = try url.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)

        let isWriteable = self is Editable

        let pluginModel = FsPluginModel(
            id: id, isWriteable: isWriteable, bookmarkData: bookmarkData,
            shouldSync: supports(.sync))

        if let db {
            try pluginModel.save(db)
        } else {
            guard let dbPool = DbService.shared.appDb else {
                throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
            }
            try dbPool.write { db in try pluginModel.save(db) }
        }
    }

    override func deletePlugin() throws {
        Logger.fsPlugin.debug("Deleting plugin: \(id)")
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        _ = try db.write { db in try FsPluginModel.deleteOne(db, key: id) }
    }

    override func isOnline() async throws -> Bool { db != nil }

    // MARK: - Helper Functions

    nonisolated private static func convertToManga(_ mangaModel: FsMangaModel, db: Database) throws
        -> Manga?
    {
        let cover = try mangaModel.cover.fetchOne(db)
        let latestChapter = try mangaModel.latestChapter.fetchOne(db)

        var mangaDict: [String: Any] = ["id": mangaModel.id]

        if let title = mangaModel.title { mangaDict["title"] = title }

        if let coverPath = cover?.path { mangaDict["cover"] = coverPath }

        if let status = mangaModel.status { mangaDict["status"] = UInt(status) }

        if let chapter = latestChapter {
            mangaDict["latestChapter"] = [
                "id": chapter.id.flatMap { String($0) }, "title": chapter.title
            ]
        }

        return Manga(from: mangaDict)
    }

    nonisolated private static func convertToDetailedManga(
        _ mangaModel: FsMangaModel, db: Database, isEditable: Bool
    ) throws -> DetailedManga? {
        let cover = try mangaModel.cover.fetchOne(db)
        let latestChapter = try mangaModel.latestChapter.fetchOne(db)
        let chapterGroupModels = try mangaModel.chapters.order(Column("id").asc).fetchAll(db)

        var mangaDict: [String: Any] = ["id": mangaModel.id]

        if let title = mangaModel.title { mangaDict["title"] = title }

        if let coverPath = cover?.path { mangaDict["cover"] = coverPath }

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

        if let chapter = latestChapter {
            mangaDict["latestChapter"] = [
                "id": chapter.id.flatMap { String($0) }, "title": chapter.title
            ]
        }

        var chapterGroups = ChapterGroups()
        for group in chapterGroupModels {
            let chapters = try group.chapters.fetchAll(db)
            let chaptersArray = chapters.sorted { $0.sequence < $1.sequence }
                .map { chapter in Chapter(id: String(chapter.id!), title: chapter.title) }
            chapterGroups.append(
                ChapterGroup(
                    id: isEditable ? group.id.map(String.init) : nil, title: group.title,
                    chapters: chaptersArray))
        }
        let chapterGroupsData = try JSONEncoder().encode(chapterGroups)
        mangaDict["chapters"] = try JSONSerialization.jsonObject(with: chapterGroupsData)

        return DetailedManga(from: mangaDict)
    }

    override func getSuggestions(_ query: String) async throws -> [String] {
        Logger.fsPlugin.debug("Getting suggestions for query: \(query)")
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for suggestions")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        return try await db.read { db in
            let searchQuery = "%\(query.lowercased())%"
            let mangas =
                try FsMangaModel.filter(sql: "LOWER(title) LIKE ?", arguments: [searchQuery])
                .limit(Int(ReadFsPluginConstants.suggestionLimit)).fetchAll(db)

            return mangas.compactMap { $0.title }
        }
    }

    override func search(_ query: String, page: UInt, genre: Genre, status: Status, isAuthor: Bool)
        async throws -> [Manga]
    {
        Logger.fsPlugin.debug(
            "Searching for: \(query), page: \(page), genre: \(genre), status: \(status), isAuthor: \(isAuthor)"
        )
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for search")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        return try await db.read { db in
            let searchQuery = "%\(query.lowercased())%"
            let offset = Int((page - 1) * ReadFsPluginConstants.pageLimit)
            let limit = Int(ReadFsPluginConstants.pageLimit)

            let searchColumn = isAuthor ? "authors" : "title"
            var query = FsMangaModel.filter(
                sql: "LOWER(\(searchColumn)) LIKE ?", arguments: [searchQuery])

            // Filter by genre if not "all"
            if genre != .all {
                let genreQuery = "%\(genre.rawValue.lowercased())%"
                query = query.filter(sql: "LOWER(genres) LIKE ?", arguments: [genreQuery])
            }

            // Filter by status if not "any"
            if status != .any { query = query.filter(Column("status") == Int(status.rawValue)) }

            let mangas = try query.limit(limit, offset: offset).fetchAll(db)

            return try mangas.compactMap { mangaModel in try Self.convertToManga(mangaModel, db: db)
            }
        }
    }

    override func getList(page: UInt, genre: Genre, status: Status) async throws -> [Manga] {
        Logger.fsPlugin.debug("Getting list, page: \(page), genre: \(genre), status: \(status)")
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for list")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        return try await db.read { db in
            let offset = Int((page - 1) * ReadFsPluginConstants.pageLimit)
            let limit = Int(ReadFsPluginConstants.pageLimit)

            var query = FsMangaModel.all()

            // Filter by genre if not "all"
            if genre != .all {
                let genreQuery = "%\(genre.rawValue)%"
                query = query.filter(sql: "LOWER(genres) LIKE ?", arguments: [genreQuery])
            }

            // Filter by status if not "any"
            if status != .any { query = query.filter(Column("status") == Int(status.rawValue)) }

            let mangas = try query.limit(limit, offset: offset).fetchAll(db)

            return try mangas.compactMap { mangaModel in try Self.convertToManga(mangaModel, db: db)
            }
        }
    }

    override func getMangas(_ ids: [String]) async throws -> [Manga] {
        Logger.fsPlugin.debug("Getting \(ids.count) mangas")
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for getMangas")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        return try await db.read { db in
            let mangas = try FsMangaModel.filter(ids.contains(Column("id"))).fetchAll(db)

            return try mangas.compactMap { mangaModel in try Self.convertToManga(mangaModel, db: db)
            }
        }
    }

    override func getDetailedManga(_ id: String) async throws -> DetailedManga {
        Logger.fsPlugin.debug("Getting detailed manga: \(id)")
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for getDetailedManga")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }
        let isEditable = self is Editable

        return try await db.read { db in
            guard let mangaModel = try FsMangaModel.fetchOne(db, key: id) else {
                Logger.fsPlugin.warning("Manga not found in DB: \(id)")
                throw MankaiErrorCode.pluginFilesystemMangaDirectoryNotFound.makeError()
            }

            guard
                let detailedManga = try Self.convertToDetailedManga(
                    mangaModel, db: db, isEditable: isEditable)
            else {
                Logger.fsPlugin.error("Failed to convert manga model to detailed manga: \(id)")
                throw MankaiErrorCode.pluginFilesystemFailedToLoadMangaDetails.makeError()
            }

            return detailedManga
        }
    }

    override func getChapter(manga _: DetailedManga, chapter: Chapter) async throws -> [String] {
        Logger.fsPlugin.debug("Getting chapter: \(chapter.id)")
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for getChapter")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        guard let chapterIdInt = Int(chapter.id) else {
            Logger.fsPlugin.error("Invalid chapter ID: \(chapter.id)")
            throw MankaiErrorCode.pluginFilesystemInvalidMangaOrChapterFormat.makeError()
        }

        return try await db.read { db in
            let images = try FsImageModel.filter(Column("chapterId") == chapterIdInt).fetchAll(db)

            return images.sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }.map { $0.path }
        }
    }

    override func getImage(_ path: String) async throws -> Data {
        Logger.fsPlugin.debug("Getting image: \(path)")
        let fileManager = FileManager.default
        let fullImagePath = url.appendingPathComponent(path).path

        guard fileManager.fileExists(atPath: fullImagePath) else {
            Logger.fsPlugin.error("Image file not found: \(fullImagePath)")
            throw MankaiErrorCode.pluginFilesystemFailedToLoadImage.makeError()
        }

        do { return try Data(contentsOf: URL(fileURLWithPath: fullImagePath)) } catch {
            Logger.fsPlugin.error("Failed to load image data: \(fullImagePath)", error: error)
            throw MankaiErrorCode.pluginFilesystemFailedToLoadImage.makeError()
        }
    }
}
