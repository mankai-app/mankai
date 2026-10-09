//
//  KavitaPlugin.swift
//  mankai
//
//  Created by Travis XU on 9/10/2026.
//

import Foundation
import GRDB

final class KavitaPlugin: Plugin, Configurable {
    private var model: KavitaPluginModel
    private var session: KavitaSession

    override class var syncType: String? { "kavita" }

    override class var typeName: String? { String(localized: "kavita") }

    override class var typeCapabilities: [PluginTypeCapability] {
        [.urlDecoding, .cache, .download]
    }

    override var capabilities: [PluginCapability] {
        [
            .onlineCheck, .suggestions, .list, .listByStatus, .search, .searchByStatus,
            .mangaDetails, .batchMangas, .chapter, .image, .urlEncoding, .sync
        ]
    }

    override var id: String { model.id }

    override var name: String? {
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Kavita (\(session.configuration.baseURL.host ?? ""))" : name
    }

    override var description: String? { String(localized: "kavitaSourceDescription") }

    init(
        id: String? = nil, baseUrl: String, name: String = "", username: String = "",
        password: String = "", apiKey: String = ""
    ) throws {
        let configuration = try KavitaConnectionConfiguration(
            baseUrl: baseUrl, username: username, password: password, apiKey: apiKey)

        model = KavitaPluginModel(
            id: id ?? configuration.baseURL.stablePluginID(prefix: "kavita"),
            baseUrl: configuration.baseURL.absoluteString, name: name, username: username,
            password: password, apiKey: apiKey)
        session = KavitaSession(configuration: configuration)

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
                description: String(localized: "kavitaAuthenticationHint"), type: .password,
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

    private func updateConfiguration(_ updatedModel: KavitaPluginModel) throws {
        let configuration = try KavitaConnectionConfiguration(
            baseUrl: updatedModel.baseUrl, username: updatedModel.username,
            password: updatedModel.password, apiKey: updatedModel.apiKey)

        model = updatedModel

        session = KavitaSession(configuration: configuration)
        (PluginService.shared.getPlugin(id) as? CacheWrapper)?.clearAllCache()
        objectWillChange.send()
    }

    // MARK: - Persistence and Sync

    override func encodeURL() -> String { configuredURL(model.baseUrl, values: configValues)! }

    override class func decodeURL(_ url: String, sourceId: String? = nil) async -> Plugin? {
        guard let configuration = PluginURLConfiguration(url) else { return nil }

        let values = configuration.configValues

        return try? KavitaPlugin(
            id: sourceId, baseUrl: configuration.baseURL.absoluteString, name: values["name"] ?? "",
            username: values["username"] ?? "", password: values["password"] ?? "",
            apiKey: values["apiKey"] ?? "")
    }

    private static func fromDataModel(_ model: KavitaPluginModel) throws -> KavitaPlugin {
        try KavitaPlugin(
            id: model.id, baseUrl: model.baseUrl, name: model.name, username: model.username,
            password: model.password, apiKey: model.apiKey)
    }

    override class func loadPlugins() -> [Plugin] {
        guard let db = DbService.shared.appDb else { return [] }

        do {
            return try db.read { db in
                try KavitaPluginModel.fetchAll(db)
                    .compactMap { model in
                        do { return try fromDataModel(model) } catch {
                            Logger.kavitaPlugin.error(
                                "Failed to load Kavita plugin: \(model.id)", error: error)

                            return nil
                        }
                    }
            }
        } catch {
            Logger.kavitaPlugin.error("Failed to load Kavita plugins", error: error)
            return []
        }
    }

    override class func loadStoredURL(_ id: String, in db: Database) throws -> String? {
        guard let model = try KavitaPluginModel.fetchOne(db, key: id) else { return nil }

        return try fromDataModel(model).encodeURL()
    }

    override class func deleteStoredPlugin(_ id: String, in db: Database) throws {
        _ = try KavitaPluginModel.filter(Column("id") == id).deleteAll(db)
    }

    override func savePlugin(db: Database? = nil) throws {
        let model = model
        if let db {
            try model.save(db)
        } else {
            guard let dbPool = DbService.shared.appDb else {
                throw MankaiErrorCode.pluginKavitaDatabaseNotAvailable.makeError()
            }
            try dbPool.write { try model.save($0) }
        }
    }

    override func deletePlugin() throws {
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.pluginKavitaDatabaseNotAvailable.makeError()
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
        // Kavita genre tags are arbitrary, only advertise status filtering.
        guard genre == .all else { return [] }
        let series = try await session.seriesList(
            page: page, query: nil, statuses: statuses(for: status))
        return try series.map { try manga($0, status: status == .any ? nil : status) }
    }

    override func search(_ query: String, page: UInt, genre: Genre, status: Status, isAuthor: Bool)
        async throws -> [Manga]
    {
        guard genre == .all, !isAuthor else { return [] }
        let series = try await session.seriesList(
            page: page, query: query, statuses: statuses(for: status))
        return try series.map { try manga($0, status: status == .any ? nil : status) }
    }

    override func getMangas(_ ids: [String]) async throws -> [Manga] {
        var mangas: [Manga] = []
        for id in ids {
            try Task.checkCancellation()
            do {
                let session = session
                async let seriesRequest = session.series(id: id)
                async let metadataRequest = session.metadata(seriesId: id)
                async let volumesRequest = session.volumes(seriesId: id)
                let (series, metadata, volumes) = try await (
                    seriesRequest, metadataRequest, volumesRequest
                )
                guard isReadable(series.format) else { continue }
                mangas.append(
                    try manga(
                        series, status: status(metadata.publicationStatus),
                        latestChapter: latestChapter(volumes)))
            } catch let error
                where (error as NSError).userInfo[MankaiErrorUserInfoKey.httpStatusCode] as? Int
                == 404
            {
                // Removed or inaccessible series should not prevent other titles from updating.
                continue
            }
        }
        return mangas
    }

    override func getDetailedManga(_ id: String) async throws -> DetailedManga {
        let session = session
        async let seriesRequest = session.series(id: id)
        async let metadataRequest = session.metadata(seriesId: id)
        async let volumesRequest = session.volumes(seriesId: id)
        let (series, metadata, volumes) = try await (seriesRequest, metadataRequest, volumesRequest)
        guard isReadable(series.format) else {
            throw MankaiErrorCode.pluginKavitaInvalidResponse.makeError()
        }

        var result = DetailedManga()
        result.id = String(series.id)
        result.title = title(series)
        result.cover = try cover(series.id)
        result.status = status(metadata.publicationStatus)
        result.latestChapter = latestChapter(volumes)
        result.description = metadata.summary
        result.externalLink = try session.configuration
            .url(path: ["library", String(series.libraryId), "series", String(series.id)])
            .absoluteString
        result.updatedAt = date(series.lastChapterAddedUtc ?? series.lastChapterAdded)
        var authors = Set<String>()
        result.authors = (metadata.writers ?? []).compactMap(\.name)
            .filter { !$0.isEmpty && authors.insert($0).inserted }
        result.genres = BrowsableMangaUtilities.genres(
            from: (metadata.genres ?? []).compactMap(\.title))
        result.chapters = chapterGroups(volumes)
        return result
    }

    override func getChapter(manga: DetailedManga, chapter: Chapter) async throws -> [String] {
        let session = session
        let info = try await session.chapterInfo(chapterId: chapter.id)
        guard String(info.seriesId) == manga.id, isReadable(info.seriesFormat), info.pages > 0
        else { throw MankaiErrorCode.pluginKavitaInvalidResponse.makeError() }
        // Kavita page indexes are zero-based.
        return try (0..<info.pages)
            .map { page in
                try session.configuration
                    .url(
                        path: ["api", "Reader", "image"],
                        query: [
                            URLQueryItem(name: "chapterId", value: chapter.id),
                            URLQueryItem(name: "page", value: String(page)),
                            URLQueryItem(name: "extractPdf", value: "true")
                        ]
                    )
                    .absoluteString
            }
    }

    override func getImage(_ url: String) async throws -> Data {
        guard let url = URL.normalizedHTTPURL(url, allowsQuery: true) else {
            throw MankaiErrorCode.pluginKavitaInvalidUrl.makeError()
        }
        return try await session.image(url: url)
    }

    // MARK: - Metadata Mapping

    private func isReadable(_ format: Int) -> Bool { [0, 1, 4].contains(format) }

    private func title(_ series: KavitaSeries) -> String {
        [series.localizedName, series.name].compactMap { $0 }.first { !$0.isEmpty }
            ?? String(series.id)
    }

    private func cover(_ id: Int) throws -> String {
        try session.configuration
            .url(
                path: ["api", "Image", "series-cover"],
                query: [URLQueryItem(name: "seriesId", value: String(id))]
            )
            .absoluteString
    }

    private func manga(_ series: KavitaSeries, status: Status? = nil, latestChapter: Chapter? = nil)
        throws -> Manga
    {
        Manga(
            id: String(series.id), title: title(series), cover: try cover(series.id),
            status: status, latestChapter: latestChapter, updates: nil, meta: nil)
    }

    private func chapter(_ chapter: KavitaChapter) -> Chapter {
        let title = [chapter.titleName, chapter.title, chapter.range, chapter.number]
            .compactMap { $0 }.first { !$0.isEmpty }
        return Chapter(id: String(chapter.id), title: title ?? String(chapter.id))
    }

    private func orderedVolumes(_ volumes: [KavitaVolume]) -> [KavitaVolume] {
        volumes.sorted {
            $0.sortNumber == $1.sortNumber ? $0.id < $1.id : $0.sortNumber < $1.sortNumber
        }
    }

    private func orderedChapters(_ chapters: [KavitaChapter]) -> [KavitaChapter] {
        chapters.filter { $0.pages > 0 }
            .sorted {
                $0.sortNumber == $1.sortNumber ? $0.id < $1.id : $0.sortNumber < $1.sortNumber
            }
    }

    private func latestChapter(_ volumes: [KavitaVolume]) -> Chapter? {
        let chapters = orderedVolumes(volumes).flatMap { orderedChapters($0.chapters ?? []) }
        return (chapters.last { !$0.isSpecial } ?? chapters.last).map(chapter)
    }

    private func chapterGroups(_ volumes: [KavitaVolume]) -> ChapterGroups {
        var groups: ChapterGroups = []
        var specials: [KavitaChapter] = []
        var seen = Set<Int>()
        for volume in orderedVolumes(volumes) {
            let chapters = orderedChapters(volume.chapters ?? [])
                .filter { seen.insert($0.id).inserted }
            specials += chapters.filter(\.isSpecial)
            let regular = chapters.filter { !$0.isSpecial }
            guard !regular.isEmpty else { continue }
            let title =
                volume.sortNumber == 0
                ? String(localized: "series")
                : "\(String(localized: "volume")) \(volume.name ?? String(volume.sortNumber))"
            groups.append(
                ChapterGroup(id: String(volume.id), title: title, chapters: regular.map(chapter)))
        }
        if !specials.isEmpty {
            groups.append(
                ChapterGroup(
                    id: "specials", title: "extra", chapters: orderedChapters(specials).map(chapter)
                ))
        }
        return groups
    }

    private func statuses(for status: Status) -> [Int] {
        switch status { case .any: [] case .onGoing: [0, 1] case .completed: [2, 3, 4]
        }
    }

    private func status(_ value: Int?) -> Status? {
        switch value { case 0, 1: .onGoing case 2, 3, 4: .completed default: nil
        }
    }

    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Kavita also returns UTC dates without a timezone suffix on older versions.
        let normalized =
            value.range(of: #"([zZ]|[+-]\d{2}:\d{2})$"#, options: .regularExpression) == nil
            ? value + "Z" : value
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }
}
