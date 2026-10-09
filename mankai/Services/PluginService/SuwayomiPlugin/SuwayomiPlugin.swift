//
//  SuwayomiPlugin.swift
//  mankai
//
//  Created by Travis XU on 9/10/2026.
//

import Foundation
import GRDB

final class SuwayomiPlugin: Plugin, Configurable {
    private var model: SuwayomiPluginModel
    private var session: SuwayomiSession

    override class var syncType: String? { "suwayomi" }

    override class var typeName: String? { String(localized: "suwayomi") }

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
        return name.isEmpty ? "Suwayomi (\(session.configuration.baseURL.host ?? ""))" : name
    }

    override var description: String? { String(localized: "suwayomiSourceDescription") }

    init(
        id: String? = nil, baseUrl: String, name: String = "", username: String = "",
        password: String = "", authMode: String = "basic_auth"
    ) throws {
        let configuration = try SuwayomiConnectionConfiguration(
            baseUrl: baseUrl, username: username, password: password, authMode: authMode)

        model = SuwayomiPluginModel(
            id: id ?? configuration.baseURL.stablePluginID(prefix: "suwayomi"),
            baseUrl: configuration.baseURL.absoluteString, name: name, username: username,
            password: password, authMode: authMode)
        session = SuwayomiSession(configuration: configuration)

        super.init()
    }

    // MARK: - Configuration

    var configs: [Config] {
        [
            Config(key: "name", name: "name", type: .text, defaultValue: ""),
            Config(key: "username", name: "username", type: .text, defaultValue: ""),
            Config(key: "password", name: "password", type: .password, defaultValue: ""),
            Config(
                key: "authMode", name: "suwayomiAuthMode",
                description: String(localized: "suwayomiAuthenticationHint"), type: .select,
                defaultValue: "none",
                options: SuwayomiConnectionConfiguration.AuthMode.allCases.map(\.rawValue))
        ]
    }

    var configValues: [ConfigValue] {
        [
            ConfigValue(key: "name", value: model.name),
            ConfigValue(key: "username", value: model.username),
            ConfigValue(key: "password", value: model.password),
            ConfigValue(key: "authMode", value: model.authMode)
        ]
    }

    func getConfig(_ key: String) -> Any { configValues.first { $0.key == key }?.value ?? NSNull() }

    func setConfig(key: String, value: Any) throws {
        guard let value = value as? String, getConfig(key) as? String != value else { return }

        var updatedModel = model

        switch key { case "name": updatedModel.name = value

            case "username": updatedModel.username = value

            case "password": updatedModel.password = value

            case "authMode": updatedModel.authMode = value

            default: return
        }

        try updateConfiguration(updatedModel)
    }

    func resetConfigs() throws {
        var updatedModel = model
        updatedModel.name = ""
        updatedModel.username = ""
        updatedModel.password = ""
        updatedModel.authMode = "none"

        try updateConfiguration(updatedModel)
    }

    private func updateConfiguration(_ updatedModel: SuwayomiPluginModel) throws {
        let configuration = try SuwayomiConnectionConfiguration(
            baseUrl: updatedModel.baseUrl, username: updatedModel.username,
            password: updatedModel.password, authMode: updatedModel.authMode)

        model = updatedModel

        session = SuwayomiSession(configuration: configuration)
        (PluginService.shared.getPlugin(id) as? CacheWrapper)?.clearAllCache()
        objectWillChange.send()
    }

    // MARK: - Persistence and Sync

    override func encodeURL() -> String { configuredURL(model.baseUrl, values: configValues)! }

    override class func decodeURL(_ url: String, sourceId: String? = nil) async -> Plugin? {
        guard let configuration = PluginURLConfiguration(url) else { return nil }

        let values = configuration.configValues

        return try? SuwayomiPlugin(
            id: sourceId, baseUrl: configuration.baseURL.absoluteString, name: values["name"] ?? "",
            username: values["username"] ?? "", password: values["password"] ?? "",
            authMode: values["authMode"] ?? "basic_auth")
    }

    private static func fromDataModel(_ model: SuwayomiPluginModel) throws -> SuwayomiPlugin {
        try SuwayomiPlugin(
            id: model.id, baseUrl: model.baseUrl, name: model.name, username: model.username,
            password: model.password, authMode: model.authMode)
    }

    override class func loadPlugins() -> [Plugin] {
        guard let db = DbService.shared.appDb else { return [] }

        do {
            return try db.read { db in
                try SuwayomiPluginModel.fetchAll(db)
                    .compactMap { model in
                        do { return try fromDataModel(model) } catch {
                            Logger.suwayomiPlugin.error(
                                "Failed to load Suwayomi plugin: \(model.id)", error: error)

                            return nil
                        }
                    }
            }
        } catch {
            Logger.suwayomiPlugin.error("Failed to load Suwayomi plugins", error: error)
            return []
        }
    }

    override class func loadStoredURL(_ id: String, in db: Database) throws -> String? {
        guard let model = try SuwayomiPluginModel.fetchOne(db, key: id) else { return nil }

        return try fromDataModel(model).encodeURL()
    }

    override class func deleteStoredPlugin(_ id: String, in db: Database) throws {
        _ = try SuwayomiPluginModel.filter(Column("id") == id).deleteAll(db)
    }

    override func savePlugin(db: Database? = nil) throws {
        let model = model
        if let db {
            try model.save(db)
        } else {
            guard let dbPool = DbService.shared.appDb else {
                throw MankaiErrorCode.pluginSuwayomiDatabaseNotAvailable.makeError()
            }
            try dbPool.write { try model.save($0) }
        }
    }

    override func deletePlugin() throws {
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.pluginSuwayomiDatabaseNotAvailable.makeError()
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
        let mangas = try await session.mangaList(page: 1, query: query, statuses: [])
        var seen = Set<String>()
        return mangas.map(\.title).filter { seen.insert($0).inserted }
    }

    override func getList(page: UInt, genre: Genre, status: Status) async throws -> [Manga] {
        guard genre == .all else { return [] }
        return try await session.mangaList(page: page, query: nil, statuses: statuses(for: status))
            .map(manga)
    }

    override func search(_ query: String, page: UInt, genre: Genre, status: Status, isAuthor: Bool)
        async throws -> [Manga]
    {
        guard genre == .all else { return [] }
        return
            try await session.mangaList(
                page: page, query: query, statuses: statuses(for: status), isAuthor: isAuthor
            )
            .map(manga)
    }

    override func getMangas(_ ids: [String]) async throws -> [Manga] {
        try await session.mangas(ids: ids).map(manga)
    }

    override func getDetailedManga(_ id: String) async throws -> DetailedManga {
        let details = try await session.detailedManga(id: id)
        let series = details.manga
        let chapters = details.chapters.sorted {
            ($0.sourceOrder ?? $0.id) < ($1.sourceOrder ?? $1.id)
        }

        var result = DetailedManga()
        result.id = String(series.id)
        result.title = series.title
        result.cover = cover(series.id)
        result.status = status(series.status)
        result.latestChapter = series.latestChapter.map(chapter) ?? chapters.last.map(chapter)
        result.description = series.description
        result.externalLink = series.realUrl.flatMap {
            URL.normalizedHTTPURL($0, allowsQuery: true)?.absoluteString
        }
        result.updatedAt = series.lastFetchedAt.flatMap {
            $0.value > 0 ? Date(timeIntervalSince1970: $0.value) : nil
        }
        var seen = Set<String>()
        result.authors = [series.author, series.artist].compactMap { $0 }
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        result.genres = BrowsableMangaUtilities.genres(from: series.genre ?? [])
        result.chapters = [ChapterGroup(title: "series", chapters: chapters.map(chapter))]
        return result
    }

    override func getChapter(manga: DetailedManga, chapter: Chapter) async throws -> [String] {
        try await session.pages(mangaId: manga.id, chapterId: chapter.id)
    }

    override func getImage(_ url: String) async throws -> Data {
        guard let url = URL.normalizedHTTPURL(url, allowsQuery: true) else {
            throw MankaiErrorCode.pluginSuwayomiInvalidUrl.makeError()
        }
        return try await session.image(url: url)
    }

    // MARK: - Metadata Mapping

    private func cover(_ id: Int) -> String {
        session.configuration.url(path: ["api", "v1", "manga", String(id), "thumbnail"])
            .absoluteString
    }

    private func manga(_ series: SuwayomiManga) -> Manga {
        Manga(
            id: String(series.id), title: series.title, cover: cover(series.id),
            status: status(series.status), latestChapter: series.latestChapter.map(chapter),
            updates: nil, meta: nil)
    }

    private func chapter(_ chapter: SuwayomiChapter) -> Chapter {
        Chapter(id: String(chapter.id), title: chapter.name)
    }

    private func statuses(for status: Status) -> [String] {
        switch status { case .any: [] case .onGoing: ["ONGOING", "ON_HIATUS"] case .completed:
            ["COMPLETED", "PUBLISHING_FINISHED", "CANCELLED"]
        }
    }

    private func status(_ value: String?) -> Status? {
        switch value?.uppercased() { case "ONGOING", "ON_HIATUS": .onGoing
            case "COMPLETED", "PUBLISHING_FINISHED", "CANCELLED": .completed
            default: nil
        }
    }
}
