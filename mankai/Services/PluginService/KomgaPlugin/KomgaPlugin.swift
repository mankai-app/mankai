//
//  KomgaPlugin.swift
//  mankai
//
//  Created by Travis XU on 8/10/2026.
//

import Foundation
import GRDB

final class KomgaPlugin: Plugin, Configurable {
    private var model: KomgaPluginModel
    private var session: KomgaSession

    override class var syncType: String? { "komga" }

    override class var typeCapabilities: [PluginTypeCapability] {
        [.urlDecoding, .cache, .download]
    }

    override var capabilities: [PluginCapability] {
        [
            .onlineCheck, .suggestions, .list, .listByStatus, .search, .searchByStatus,
            .searchByAuthor, .mangaDetails, .batchMangas, .chapter, .image, .urlEncoding, .sync
        ]
    }

    override var id: String { model.id }

    override var name: String? {
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Komga (\(session.configuration.baseURL.host ?? ""))" : name
    }

    override var tags: [String] { [String(localized: "komga")] }

    override var description: String? { String(localized: "komgaSourceDescription") }

    init(
        id: String? = nil, baseUrl: String, name: String = "", username: String = "",
        password: String = "", apiKey: String = ""
    ) throws {
        let configuration = try KomgaConnectionConfiguration(
            baseUrl: baseUrl, username: username, password: password, apiKey: apiKey)

        model = KomgaPluginModel(
            id: id ?? configuration.baseURL.stablePluginID(prefix: "komga"),
            baseUrl: configuration.baseURL.absoluteString, name: name, username: username,
            password: password, apiKey: apiKey)
        session = KomgaSession(configuration: configuration)

        super.init()
    }

    // MARK: - Configuration

    var configs: [Config] {
        [
            Config(key: "name", name: "name", type: .text, defaultValue: ""),
            Config(key: "username", name: "username", type: .text, defaultValue: ""),
            Config(key: "password", name: "password", type: .password, defaultValue: ""),
            Config(
                key: "apiKey", name: "apiKey",
                description: String(localized: "komgaAuthenticationHint"), type: .password,
                defaultValue: "")
        ]
    }

    var configValues: [ConfigValue] {
        [
            ConfigValue(key: "name", value: model.name),
            ConfigValue(key: "username", value: model.username),
            ConfigValue(key: "password", value: model.password),
            ConfigValue(key: "apiKey", value: model.apiKey)
        ]
    }

    func getConfig(_ key: String) -> Any { configValues.first { $0.key == key }?.value ?? NSNull() }

    func setConfig(key: String, value: Any) throws {
        guard let value = value as? String, getConfig(key) as? String != value else { return }

        var updatedModel = model

        switch key { case "name": updatedModel.name = value

            case "username": updatedModel.username = value

            case "password": updatedModel.password = value

            case "apiKey": updatedModel.apiKey = value

            default: return
        }

        try updateConfiguration(updatedModel)
    }

    func resetConfigs() throws {
        var updatedModel = model
        updatedModel.name = ""
        updatedModel.username = ""
        updatedModel.password = ""
        updatedModel.apiKey = ""

        try updateConfiguration(updatedModel)
    }

    private func updateConfiguration(_ updatedModel: KomgaPluginModel) throws {
        let configuration = try KomgaConnectionConfiguration(
            baseUrl: updatedModel.baseUrl, username: updatedModel.username,
            password: updatedModel.password, apiKey: updatedModel.apiKey)

        model = updatedModel

        session = KomgaSession(configuration: configuration)
        (PluginService.shared.getPlugin(id) as? CacheWrapper)?.clearAllCache()
        objectWillChange.send()
    }

    // MARK: - Persistence and Sync

    override func encodeURL() -> String { configuredURL(model.baseUrl, values: configValues)! }

    override class func decodeURL(_ url: String, sourceId: String? = nil) async -> Plugin? {
        guard let configuration = PluginURLConfiguration(url) else { return nil }

        let values = configuration.configValues

        return try? KomgaPlugin(
            id: sourceId, baseUrl: configuration.baseURL.absoluteString, name: values["name"] ?? "",
            username: values["username"] ?? "", password: values["password"] ?? "",
            apiKey: values["apiKey"] ?? "")
    }

    private static func fromDataModel(_ model: KomgaPluginModel) throws -> KomgaPlugin {
        try KomgaPlugin(
            id: model.id, baseUrl: model.baseUrl, name: model.name, username: model.username,
            password: model.password, apiKey: model.apiKey)
    }

    override class func loadPlugins() -> [Plugin] {
        guard let db = DbService.shared.appDb else { return [] }

        do {
            return try db.read { db in
                try KomgaPluginModel.fetchAll(db)
                    .compactMap { model in
                        do { return try fromDataModel(model) } catch {
                            Logger.komgaPlugin.error(
                                "Failed to load Komga plugin: \(model.id)", error: error)

                            return nil
                        }
                    }
            }
        } catch {
            Logger.komgaPlugin.error("Failed to load Komga plugins", error: error)
            return []
        }
    }

    override class func loadStoredURL(_ id: String, in db: Database) throws -> String? {
        guard let model = try KomgaPluginModel.fetchOne(db, key: id) else { return nil }

        return try fromDataModel(model).encodeURL()
    }

    override class func deleteStoredPlugin(_ id: String, in db: Database) throws {
        _ = try KomgaPluginModel.filter(Column("id") == id).deleteAll(db)
    }

    override func savePlugin(db: Database? = nil) throws {
        let model = model
        if let db {
            try model.save(db)
        } else {
            guard let dbPool = DbService.shared.appDb else {
                throw MankaiErrorCode.pluginKomgaDatabaseNotAvailable.makeError()
            }
            try dbPool.write { try model.save($0) }
        }
    }

    override func deletePlugin() throws {
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.pluginKomgaDatabaseNotAvailable.makeError()
        }

        let id = id
        try db.write { try Self.deleteStoredPlugin(id, in: $0) }
    }

    // MARK: - Manga API

    func validateConnection() async throws { try await session.validateConnection() }

    override func isOnline() async throws -> Bool {
        do {
            try await validateConnection()
            return true
        } catch {
            try Task.checkCancellation()
            return false
        }
    }

    override func getSuggestions(_ query: String) async throws -> [String] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let series = try await session.seriesList(page: 1, query: query, statuses: [])
        var seen = Set<String>()
        return series.map(title).filter { seen.insert($0).inserted }
    }

    override func getList(page: UInt, genre: Genre, status: Status) async throws -> [Manga] {
        // Genre names in Komga are arbitrary, only advertise status filtering.
        guard genre == .all else { return [] }

        return try await session.seriesList(page: page, query: nil, statuses: statuses(for: status))
            .map { manga($0) }
    }

    override func search(_ query: String, page: UInt, genre: Genre, status: Status, isAuthor: Bool)
        async throws -> [Manga]
    {
        guard genre == .all else { return [] }

        return
            try await session.seriesList(
                page: page, query: query, statuses: statuses(for: status), isAuthor: isAuthor
            )
            .map { manga($0) }
    }

    override func getMangas(_ ids: [String]) async throws -> [Manga] {
        var mangas: [Manga] = []

        for id in ids {
            try Task.checkCancellation()

            do {
                let series = try await session.series(id: id)
                let latest = try await session.books(seriesId: id, latestOnly: true).first

                mangas.append(manga(series, latestChapter: latest.map(chapter)))
            } catch let error
                where (error as NSError).userInfo[MankaiErrorUserInfoKey.httpStatusCode] as? Int
                == 404
            {
                // A removed series should not prevent updates for the remaining titles.
                continue
            }
        }

        return mangas
    }

    override func getDetailedManga(_ id: String) async throws -> DetailedManga {
        let session = session

        async let seriesRequest = session.series(id: id)
        async let booksRequest = session.books(seriesId: id)

        let (series, books) = try await (seriesRequest, booksRequest)

        var result = DetailedManga()
        result.id = series.id
        result.title = title(series)
        result.cover = cover(series.id)
        result.status = status(series.metadata.status)
        result.readingDirection = readingDirection(series.metadata.readingDirection)
        result.latestChapter = books.last.map(chapter)

        result.description =
            series.metadata.summary?.isEmpty == false
            ? series.metadata.summary : series.booksMetadata?.summary
        result.externalLink = session.configuration.url(path: ["series", series.id]).absoluteString
        result.updatedAt = series.lastModified.flatMap { ISO8601DateFormatter().date(from: $0) }

        var authors = Set<String>()
        result.authors = (series.booksMetadata?.authors ?? []).map(\.name)
            .filter { authors.insert($0).inserted }

        result.genres = BrowsableMangaUtilities.genres(from: series.metadata.genres ?? [])
        result.chapters = [ChapterGroup(title: "series", chapters: books.map(chapter))]

        return result
    }

    override func getChapter(manga: DetailedManga, chapter: Chapter) async throws -> [String] {
        let session = session

        let pages = try await session.pages(bookId: chapter.id)
        guard !pages.isEmpty else { throw MankaiErrorCode.pluginKomgaInvalidResponse.makeError() }

        return pages.sorted { $0.number < $1.number }
            .map {
                session.configuration
                    .url(path: ["api", "v1", "books", chapter.id, "pages", String($0.number)])
                    .absoluteString
            }
    }

    override func getImage(_ url: String) async throws -> Data {
        guard let url = URL.normalizedHTTPURL(url, allowsQuery: true) else {
            throw MankaiErrorCode.pluginKomgaInvalidUrl.makeError()
        }

        return try await session.image(url: url)
    }

    // MARK: - Metadata Mapping

    private func title(_ series: KomgaSeries) -> String {
        series.metadata.title?.isEmpty == false ? series.metadata.title! : series.name
    }

    private func cover(_ id: String) -> String {
        session.configuration.url(path: ["api", "v1", "series", id, "thumbnail"]).absoluteString
    }

    private func manga(_ series: KomgaSeries, latestChapter: Chapter? = nil) -> Manga {
        Manga(
            id: series.id, title: title(series), cover: cover(series.id),
            status: status(series.metadata.status), latestChapter: latestChapter, updates: nil,
            meta: nil)
    }

    private func chapter(_ book: KomgaBook) -> Chapter {
        Chapter(
            id: book.id,
            title: book.metadata.title?.isEmpty == false ? book.metadata.title : book.name)
    }

    private func statuses(for status: Status) -> [String] {
        switch status { case .any: []

            case .onGoing: ["ONGOING", "HIATUS"]

            case .completed: ["ENDED", "ABANDONED"]
        }
    }

    private func status(_ value: String?) -> Status? {
        switch value?.uppercased() { case "ONGOING", "HIATUS": .onGoing

            case "ENDED", "ABANDONED": .completed

            default: nil
        }
    }

    private func readingDirection(_ value: String?) -> ReadingDirection? {
        switch value?.uppercased() { case "LEFT_TO_RIGHT": .leftToRight

            case "RIGHT_TO_LEFT": .rightToLeft

            case "VERTICAL", "WEBTOON": .vertical

            default: nil
        }
    }
}
