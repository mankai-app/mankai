//
//  JsPlugin.swift
//  mankai
//
//  Created by Travis XU on 21/6/2025.
//

import Foundation
import GRDB
import ReerCodable

enum ScriptType: String {
    case isOnline
    case getSuggestion
    case search
    case getList
    case getMangas
    case getMangaUpdates
    case getDetailedManga
    case getChapter
    case getImage
}

@Codable private struct JsPluginMetadata {
    let id: String
    let name: String?
    let version: String?
    let description: String?
    @DecodingDefault([]) let authors: [String]
    let repository: String?
    let updatesUrl: String?
    @DecodingDefault([]) let availableGenres: [Genre]
    @DecodingDefault([:]) let scripts: [String: String]
    @DecodingDefault([]) let configs: [Config]
    let getImageHeaders: [String: String]?
    let cooldown: Cooldown?
    @DecodingDefault(PluginCapability.defaultCapabilities) let capabilities: [PluginCapability]
}

final class JsPlugin: Plugin, Configurable {
    override class var syncType: String? { "js" }

    override class var typeName: String? { String(localized: "js") }

    override class var typeCapabilities: [PluginTypeCapability] {
        [.urlDecoding, .cache, .download]
    }

    // MARK: - Metadata

    private var _id: String
    private var _name: String?
    private var _version: String?
    private var _description: String?
    private var _authors: [String]
    private var _repository: String?
    private var _availableGenres: [Genre]
    private var _configs: [Config]
    private var _cooldown: Cooldown?
    private var _capabilities: [PluginCapability]

    override var id: String { _id }

    override var name: String? { _name }

    override var version: String? { _version }

    override var description: String? { _description }

    override var authors: [String] { _authors }

    override var repository: String? { _repository }

    override var availableGenres: [Genre] { _availableGenres }

    var configs: [Config] { _configs }

    lazy var _configValues: [String: ConfigValue] = {
        var configValues: [String: ConfigValue] = [:]
        for config in configs {
            configValues[config.key] = ConfigValue(key: config.key, value: config.defaultValue)
        }
        return configValues
    }()

    var configValues: [ConfigValue] { Array(_configValues.values) }

    override var cooldown: Cooldown? { _cooldown }

    override var capabilities: [PluginCapability] {
        _capabilities.filter { $0 != .sync && $0 != .urlEncoding } + [.sync]
            + (encodedURL != nil ? [.urlEncoding] : [])
    }

    private var _getImageHeaders: [String: String]?
    private var _updatesUrl: String?
    var updatesUrl: String? { _updatesUrl }
    private var sourceURL: String?
    private var encodedURL: String? {
        (sourceURL ?? updatesUrl).flatMap { configuredURL($0, values: configValues) }
    }

    override func encodeURL() -> String { encodedURL! }

    // MARK: - Methods Scripts

    private var _scripts: [ScriptType: String]
    private var _funcName: [ScriptType: String] = [:]
    private var _scriptsNoExport: [ScriptType: String] = [:]

    // MARK: - Init

    init(
        id: String, name: String? = nil, version: String? = nil, description: String? = nil,
        authors: [String] = [], repository: String? = nil, updatesUrl: String? = nil,
        availableGenres: [Genre] = [], scripts: [ScriptType: String] = [:], configs: [Config] = [],
        getImageHeaders: [String: String]? = nil, cooldown: Cooldown? = nil,
        capabilities: [PluginCapability] = PluginCapability.defaultCapabilities
    ) {
        Logger.jsPlugin.debug("Initializing JsPlugin: \(id)")
        _id = id
        _name = name
        _version = version
        _description = description
        _authors = authors
        _repository = repository
        _updatesUrl = updatesUrl
        _availableGenres = availableGenres
        _configs = configs
        _getImageHeaders = getImageHeaders
        _cooldown = cooldown
        _capabilities = capabilities

        _scripts = scripts
        for (scriptType, script) in scripts {
            guard
                let regex = try? NSRegularExpression(
                    pattern: "export\\{(.*) as default\\};", options: []),
                let match = regex.firstMatch(
                    in: script, options: [], range: NSRange(location: 0, length: script.utf16.count)
                ), let funcRange = Range(match.range(at: 1), in: script)
            else { fatalError("Invalid script format for \(scriptType.rawValue)") }

            let funcName = String(script[funcRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedScript = regex.stringByReplacingMatches(
                in: script, options: [], range: NSRange(location: 0, length: script.utf16.count),
                withTemplate: "")

            _funcName[scriptType] = funcName
            _scriptsNoExport[scriptType] = cleanedScript
        }
    }

    private func setConfigValues(_ configValues: [ConfigValue]) {
        for configValue in configValues { _configValues[configValue.key] = configValue }
    }

    func getConfig(_ key: String) -> Any { _configValues[key]!.value }

    func setConfig(key: String, value: Any) throws {
        _configValues[key] = ConfigValue(key: key, value: value)
        objectWillChange.send()
    }

    func resetConfigs() throws {
        _configValues = [:]
        for config in configs {
            _configValues[config.key] = ConfigValue(key: config.key, value: config.defaultValue)
        }
        objectWillChange.send()
    }

    static func fromJson(_ json: [String: Any]) -> JsPlugin? {
        guard let metadata = try? JsPluginMetadata.decoded(from: json) else { return nil }

        return fromMetadata(metadata)
    }

    private static func fromMetadata(_ metadata: JsPluginMetadata) -> JsPlugin? {
        let scripts = metadata.scripts.reduce(into: [ScriptType: String]()) { result, entry in
            if let scriptType = ScriptType(rawValue: entry.key) { result[scriptType] = entry.value }
        }

        return JsPlugin(
            id: metadata.id, name: metadata.name, version: metadata.version,
            description: metadata.description, authors: metadata.authors,
            repository: metadata.repository, updatesUrl: metadata.updatesUrl,
            availableGenres: metadata.availableGenres, scripts: scripts, configs: metadata.configs,
            getImageHeaders: metadata.getImageHeaders, cooldown: metadata.cooldown,
            capabilities: metadata.capabilities)
    }

    override class func decodeURL(_ url: String, sourceId: String? = nil) async -> Plugin? {
        await fromUrl(url, sourceId: sourceId)
    }

    static func fromUrl(_ urlString: String, sourceId: String? = nil) async -> JsPlugin? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }

        guard let metadata = try? JsPluginMetadata.decoded(from: data),
            let plugin = fromMetadata(metadata)
        else { return nil }

        let configMap = Dictionary(uniqueKeysWithValues: plugin.configs.map { ($0.key, $0) })
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        var matchedConfigValues: [ConfigValue] = []
        for item in queryItems {
            guard let config = configMap[item.name] else { continue }
            let parsedValue = config.type.parseValue(item.value ?? "")
            matchedConfigValues.append(ConfigValue(key: item.name, value: parsedValue))
        }

        if !matchedConfigValues.isEmpty { plugin.setConfigValues(matchedConfigValues) }

        plugin.sourceURL = trimmed
        if let sourceId { plugin._id = sourceId }

        return plugin
    }

    static func fromDataModel(_ jsPluginModel: JsPluginModel) -> JsPlugin? {
        guard let metaData = jsPluginModel.meta.data(using: .utf8),
            let metadata = try? JsPluginMetadata.decoded(from: metaData)
        else { return nil }

        let configValues = jsPluginModel.configValues.data(using: .utf8)
            .flatMap { try? [ConfigValue].decoded(from: $0) }

        let plugin = fromMetadata(metadata)
        plugin?.sourceURL = jsPluginModel.sourceURL
        plugin?._id = jsPluginModel.id

        // Update config values if they exist
        if let configValues = configValues, let plugin = plugin {
            plugin.setConfigValues(configValues)
        }

        return plugin
    }

    override class func loadStoredURL(_ id: String, in db: Database) throws -> String? {
        guard let model = try JsPluginModel.fetchOne(db, key: id) else { return nil }
        return fromDataModel(model)?.encodedURL
    }

    override class func deleteStoredPlugin(_ id: String, in db: Database) throws {
        _ = try JsPluginModel.filter(Column("id") == id).deleteAll(db)
    }

    override class func loadPlugins() -> [Plugin] {
        Logger.jsPlugin.debug("Loading JS plugins")
        guard let dbPool = DbService.shared.appDb else {
            Logger.jsPlugin.error("Database not available")
            return []
        }

        var results: [JsPlugin] = []

        do {
            try dbPool.read { db in
                let jsPluginModels = try JsPluginModel.fetchAll(db)

                for jsPluginModel in jsPluginModels {
                    if let jsPlugin = JsPlugin.fromDataModel(jsPluginModel) {
                        results.append(jsPlugin)
                    }
                }
            }
        } catch { Logger.jsPlugin.error("Failed to load plugins from GRDB", error: error) }

        Task { for plugin in results { await plugin.checkForUpdates() } }
        return results
    }

    // MARK: - Methods

    override func savePlugin(db: Database? = nil) throws {
        Logger.jsPlugin.debug("Saving plugin: \(id)")
        if let db {
            try makeModel().save(db)
            return
        }
        guard let dbPool = DbService.shared.appDb else {
            throw MankaiErrorCode.pluginJavascriptDatabaseNotAvailable.makeError()
        }

        let model = try makeModel()
        try dbPool.write { db in try model.save(db) }
    }

    private func makeModel() throws -> JsPluginModel {
        let scriptsDict = _scripts.reduce(into: [String: String]()) { dict, pair in
            dict[pair.key.rawValue] = pair.value
        }

        let metadata = JsPluginMetadata(
            id: id, name: name, version: version, description: description, authors: authors,
            repository: repository, updatesUrl: updatesUrl, availableGenres: availableGenres,
            scripts: scriptsDict, configs: configs, getImageHeaders: _getImageHeaders,
            cooldown: cooldown,
            capabilities: _capabilities.filter { $0 != .sync && $0 != .urlEncoding })
        let metaData = try metadata.encodedData()
        guard let metaString = String(data: metaData, encoding: .utf8) else {
            throw MankaiErrorCode.pluginJavascriptFailedToEncodeMetaData.makeError()
        }

        // Create config values JSON
        let configValuesData = try Array(_configValues.values).encodedData()
        guard let configValuesString = String(data: configValuesData, encoding: .utf8) else {
            throw MankaiErrorCode.pluginJavascriptFailedToEncodeConfigValuesData.makeError()
        }

        return JsPluginModel(
            id: id, meta: metaString, configValues: configValuesString, sourceURL: sourceURL)
    }

    override func deletePlugin() throws {
        Logger.jsPlugin.debug("Deleting plugin: \(id)")
        guard let dbPool = DbService.shared.appDb else {
            throw MankaiErrorCode.pluginJavascriptDatabaseNotAvailable.makeError()
        }

        let sourceId = id
        try dbPool.write { db in try Self.deleteStoredPlugin(sourceId, in: db) }
    }

    override func isOnline() async throws -> Bool {
        Logger.jsPlugin.debug("Checking isOnline for plugin: \(id)")
        if _scripts[.isOnline] == nil { fatalError("Script for isOnline is not defined") }

        let script = "\(_scriptsNoExport[.isOnline]!) return await \(_funcName[.isOnline]!)();"
        let result = try await JsRuntime.shared.execute(script, plugin: self)

        guard let isOnline = result as? Bool else {
            throw MankaiErrorCode.pluginJavascriptInvalidResultFormatForIsOnline.makeError()
        }

        return isOnline
    }

    override func getSuggestions(_ query: String) async throws -> [String] {
        Logger.jsPlugin.debug("Getting suggestions for query: \(query) (plugin: \(id))")

        if _scripts[.getSuggestion] == nil { fatalError("Script for getSuggestion is not defined") }

        let script =
            "\(_scriptsNoExport[.getSuggestion]!) return await \(_funcName[.getSuggestion]!)(\(JsRuntime.javascriptStringLiteral(query)));"
        let result = try await JsRuntime.shared.execute(script, plugin: self)

        guard let suggestions = result as? [String] else {
            throw MankaiErrorCode.pluginJavascriptInvalidResultFormatForSuggestions.makeError()
        }

        return suggestions
    }

    override func search(_ query: String, page: UInt, genre: Genre, status: Status, isAuthor: Bool)
        async throws -> [Manga]
    {
        Logger.jsPlugin.debug(
            "Searching for: \(query), page: \(page), genre: \(genre), status: \(status), isAuthor: \(isAuthor) (plugin: \(id))"
        )

        if _scripts[.search] == nil { fatalError("Script for search is not defined") }

        let script =
            "\(_scriptsNoExport[.search]!) return await \(_funcName[.search]!)(\(JsRuntime.javascriptStringLiteral(query)),\(page),\(JsRuntime.javascriptStringLiteral(genre.rawValue)),\(status.rawValue),\(isAuthor));"
        let result = try await JsRuntime.shared.execute(script, plugin: self)

        guard let mangas = result as? [Any] else {
            throw MankaiErrorCode.pluginJavascriptInvalidResultFormatForMangas.makeError()
        }

        return mangas.compactMap { Manga(from: $0) }
    }

    override func getList(page: UInt, genre: Genre, status: Status) async throws -> [Manga] {
        Logger.jsPlugin.debug(
            "Getting list, page: \(page), genre: \(genre), status: \(status) (plugin: \(id))")

        if _scripts[.getList] == nil { fatalError("Script for getList is not defined") }

        let script =
            "\(_scriptsNoExport[.getList]!) return await \(_funcName[.getList]!)(\(page),\(JsRuntime.javascriptStringLiteral(genre.rawValue)),\(status.rawValue));"
        let result = try await JsRuntime.shared.execute(script, plugin: self)

        guard let mangas = result as? [Any] else {
            throw MankaiErrorCode.pluginJavascriptInvalidResultFormatForMangas.makeError()
        }

        return mangas.compactMap { Manga(from: $0) }
    }

    override func getMangas(_ ids: [String]) async throws -> [Manga] {
        Logger.jsPlugin.debug("Getting \(ids.count) mangas (plugin: \(id))")
        if _scripts[.getMangas] == nil { fatalError("Script for getMangas is not defined") }

        let idsJson = try ids.encodedData()
        let idsString = String(data: idsJson, encoding: .utf8) ?? "[]"

        let script =
            "\(_scriptsNoExport[.getMangas]!) return await \(_funcName[.getMangas]!)(\(idsString));"
        let result = try await JsRuntime.shared.execute(script, plugin: self)

        guard let mangas = result as? [Any] else {
            throw MankaiErrorCode.pluginJavascriptInvalidResultFormatForMangas.makeError()
        }

        return mangas.compactMap { Manga(from: $0) }
    }

    override func getMangaUpdates(_ mangas: [MangaUpdateRequest]) async throws -> [Manga] {
        Logger.jsPlugin.debug("Checking updates for \(mangas.count) mangas (plugin: \(id))")
        guard supports(.mangaUpdates) else { return try await super.getMangaUpdates(mangas) }

        if _scripts[.getMangaUpdates] == nil {
            fatalError("Script for getMangaUpdates is not defined")
        }

        let mangasJson = try mangas.encodedData()
        let mangasString = String(data: mangasJson, encoding: .utf8) ?? "[]"
        let script =
            "\(_scriptsNoExport[.getMangaUpdates]!) return await \(_funcName[.getMangaUpdates]!)(\(mangasString));"
        let result = try await JsRuntime.shared.execute(script, plugin: self)

        guard let updates = result as? [Any] else {
            throw MankaiErrorCode.pluginJavascriptInvalidResultFormatForMangas.makeError()
        }

        return updates.compactMap { Manga(from: $0) }
    }

    override func getDetailedManga(_ id: String) async throws -> DetailedManga {
        Logger.jsPlugin.debug("Getting detailed manga: \(id) (plugin: \(self.id))")

        if _scripts[.getDetailedManga] == nil {
            fatalError("Script for getDetailedManga is not defined")
        }

        let script =
            "\(_scriptsNoExport[.getDetailedManga]!) return await \(_funcName[.getDetailedManga]!)(\(JsRuntime.javascriptStringLiteral(id)));"
        let result = try await JsRuntime.shared.execute(script, plugin: self)

        guard let detailedMangaJson = result as? [String: Any],
            let detailedMangaResult = try? DetailedManga.decoded(from: detailedMangaJson)
        else {
            throw MankaiErrorCode.pluginJavascriptInvalidResultFormatForDetailedManga.makeError()
        }

        return detailedMangaResult
    }

    override func getChapter(manga: DetailedManga, chapter: Chapter) async throws -> [String] {
        Logger.jsPlugin.debug("Getting chapter: \(chapter.id) (plugin: \(id))")

        if _scripts[.getChapter] == nil { fatalError("Script for getChapter is not defined") }

        let mangaJson = try manga.encodedData()
        let chapterJson = try chapter.encodedData()

        guard let mangaString = String(data: mangaJson, encoding: .utf8),
            let chapterString = String(data: chapterJson, encoding: .utf8)
        else { throw MankaiErrorCode.pluginJavascriptInvalidMangaOrChapterFormat.makeError() }

        let script =
            "\(_scriptsNoExport[.getChapter]!) return await \(_funcName[.getChapter]!)(\(mangaString),\(chapterString));"
        let result = try await JsRuntime.shared.execute(script, plugin: self)

        guard let images = result as? [String] else {
            throw MankaiErrorCode.pluginJavascriptInvalidResultFormatForImages.makeError()
        }

        return images
    }

    override func getImage(_ url: String) async throws -> Data {
        Logger.jsPlugin.debug("Getting image: \(url) (plugin: \(id))")

        if let headers = _getImageHeaders {
            return try await requestImage(url: url, headers: headers)
        }

        if _scripts[.getImage] == nil { fatalError("Script for getImage is not defined") }

        let script =
            "\(_scriptsNoExport[.getImage]!) return await \(_funcName[.getImage]!)(\(JsRuntime.javascriptStringLiteral(url)));"
        let result = try await JsRuntime.shared.execute(script, plugin: self)

        if let imageBase64Encoded = result as? String {
            guard let imageData = Data(base64Encoded: imageBase64Encoded) else {
                throw MankaiErrorCode.pluginJavascriptInvalidBase64StringForImage.makeError()
            }

            return imageData
        }

        guard let proxyRequest = result as? [String: Any],
            let proxyUrl = proxyRequest["url"] as? String,
            let headers = proxyRequest["headers"] as? [String: String]
        else { throw MankaiErrorCode.pluginJavascriptInvalidResultFormatForImage.makeError() }

        return try await requestImage(url: proxyUrl, headers: headers)
    }

    private func requestImage(url: String, headers: [String: String]) async throws -> Data {
        guard let url = URL(string: url) else {
            throw MankaiErrorCode.pluginJavascriptInvalidUrl.makeError()
        }

        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let (data, _) = try await URLSession.shared.data(for: request)

        return data
    }

    func checkForUpdates() async {
        guard let updatesUrl = updatesUrl else { return }

        Logger.jsPlugin.info("Checking for updates for plugin: \(id)")

        guard let newPlugin = await JsPlugin.fromUrl(updatesUrl) else {
            Logger.jsPlugin.error("Failed to fetch update for plugin: \(id)")
            return
        }

        if newPlugin.version != version {
            Logger.jsPlugin.info(
                "Updating plugin: \(id) from version \(version ?? "nil") to \(newPlugin.version ?? "nil")"
            )

            do {
                _name = newPlugin._name
                _version = newPlugin._version
                _description = newPlugin._description
                _authors = newPlugin._authors
                _repository = newPlugin._repository
                _availableGenres = newPlugin._availableGenres
                _configs = newPlugin._configs
                _cooldown = newPlugin._cooldown
                _capabilities = newPlugin._capabilities

                _updatesUrl = newPlugin._updatesUrl
                _getImageHeaders = newPlugin._getImageHeaders

                _scripts = newPlugin._scripts
                _funcName = newPlugin._funcName
                _scriptsNoExport = newPlugin._scriptsNoExport

                try PluginService.shared.savePlugin(self)
                Logger.jsPlugin.info("Plugin updated successfully: \(id)")
            } catch { Logger.jsPlugin.error("Failed to save updated plugin: \(id)", error: error) }
        } else {
            Logger.jsPlugin.info("Plugin is up to date: \(id)")
        }
    }
}
