//
//  HttpPlugin.swift
//  mankai
//
//  Created by Travis XU on 30/1/2026.
//

import Foundation
import GRDB
import ReerCodable

@Codable private struct HttpPluginMetadata {
    let id: String
    let name: String?
    let version: String?
    let description: String?
    @DecodingDefault([]) let authors: [String]
    let repository: String?
    @DecodingDefault([]) let availableGenres: [Genre]
    let authenticationEnabled: Bool?
    @DecodingDefault(false) let editorEnabled: Bool
    @DecodingDefault([]) let configs: [Config]
    let cooldown: Cooldown?
    @DecodingDefault(PluginCapability.defaultCapabilities) let capabilities: [PluginCapability]
}

class HttpPlugin: Plugin, Configurable {
    override class var syncType: String? { "http" }

    override class var typeCapabilities: [PluginTypeCapability] {
        [.urlDecoding, .cache, .download]
    }

    private var _id: String
    private var _name: String?
    private var _version: String?
    private var _description: String?
    private var _authors: [String]
    private var _repository: String?
    private var _availableGenres: [Genre]
    private var _cooldown: Cooldown?
    private var _capabilities: [PluginCapability]

    override var id: String { _id }

    override var name: String? { _name }

    override var version: String? { _version }

    override var description: String? { _description }

    override var authors: [String] { _authors }

    override var repository: String? { _repository }

    override var availableGenres: [Genre] { _availableGenres }

    override var cooldown: Cooldown? { _cooldown }

    override var capabilities: [PluginCapability] {
        _capabilities.filter { $0 != .sync && $0 != .urlEncoding } + [.sync]
            + (encodedURL != nil ? [.urlEncoding] : [])
    }

    var configs: [Config] {
        [
            Config(key: "username", name: "username", type: .text, defaultValue: ""),
            Config(key: "password", name: "password", type: .password, defaultValue: "")
        ]
    }

    lazy var _configValues: [String: ConfigValue] = {
        var configValues: [String: ConfigValue] = [:]
        for config in configs {
            configValues[config.key] = ConfigValue(key: config.key, value: config.defaultValue)
        }
        return configValues
    }()

    var configValues: [ConfigValue] { Array(_configValues.values) }

    private var _authenticationEnabled: Bool
    var authenticationEnabled: Bool { _authenticationEnabled }

    private var baseUrl: String
    private var encodedURL: String? { configuredURL(baseUrl, values: configValues) }

    override func encodeURL() -> String { encodedURL! }
    lazy var authManager: AuthManager = .init(id: id)
    private var isMetaUpdated: Bool = false

    private var setupTask: Task<Void, Error>?
    private let setupLock = NSLock()

    override var tags: [String] { [String(localized: "http")] }

    // MARK: - Init

    required init(
        id: String, baseUrl: String, authenticationEnabled: Bool, name: String? = nil,
        version: String? = nil, description: String? = nil, authors: [String] = [],
        repository: String? = nil, availableGenres: [Genre] = [], cooldown: Cooldown? = nil,
        capabilities: [PluginCapability] = PluginCapability.defaultCapabilities
    ) {
        Logger.httpPlugin.debug("Initializing HttpPlugin: \(id)")
        _id = id
        self.baseUrl = baseUrl
        if self.baseUrl.hasSuffix("/") { self.baseUrl.removeLast() }
        _authenticationEnabled = authenticationEnabled
        _name = name
        _version = version
        _description = description
        _authors = authors
        _repository = repository
        _availableGenres = availableGenres
        _cooldown = cooldown
        _capabilities = capabilities
    }

    private func setConfigValues(_ configValues: [ConfigValue]) {
        for configValue in configValues { _configValues[configValue.key] = configValue }
    }

    func getConfig(_ key: String) -> Any { _configValues[key]!.value }

    func setConfig(key: String, value: Any) throws {
        _configValues[key] = ConfigValue(key: key, value: value)
        objectWillChange.send()
        try PluginService.shared.savePlugin(self)
    }

    func resetConfigs() throws {
        _configValues = [:]
        for config in configs {
            _configValues[config.key] = ConfigValue(key: config.key, value: config.defaultValue)
        }
        objectWillChange.send()
        try PluginService.shared.savePlugin(self)
    }

    static func fromJson(baseUrl: String, _ json: [String: Any]) -> HttpPlugin? {
        guard let metadata = try? HttpPluginMetadata.decoded(from: json) else { return nil }

        return fromMetadata(baseUrl: baseUrl, metadata: metadata)
    }

    private static func fromMetadata(baseUrl: String, metadata: HttpPluginMetadata) -> HttpPlugin? {
        guard let authenticationEnabled = metadata.authenticationEnabled else { return nil }

        if metadata.editorEnabled, !(self is EditableHttpPlugin.Type) {
            return EditableHttpPlugin(
                id: metadata.id, baseUrl: baseUrl, authenticationEnabled: authenticationEnabled,
                name: metadata.name, version: metadata.version, description: metadata.description,
                authors: metadata.authors, repository: metadata.repository,
                availableGenres: metadata.availableGenres, cooldown: metadata.cooldown,
                capabilities: metadata.capabilities)
        }

        if !metadata.editorEnabled, self is EditableHttpPlugin.Type {
            Logger.httpPlugin.warning(
                "Plugin \(metadata.id) is not editable but EditableHttpPlugin is being used. This may cause issues."
            )
            return nil
        }

        return self.init(
            id: metadata.id, baseUrl: baseUrl, authenticationEnabled: authenticationEnabled,
            name: metadata.name, version: metadata.version, description: metadata.description,
            authors: metadata.authors, repository: metadata.repository,
            availableGenres: metadata.availableGenres, cooldown: metadata.cooldown,
            capabilities: metadata.capabilities)
    }

    override class func decodeURL(_ url: String, sourceId: String? = nil) async -> Plugin? {
        await fromUrl(url, sourceId: sourceId)
    }

    static func fromUrl(_ urlString: String, sourceId: String? = nil) async -> HttpPlugin? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }

        guard let metadata = try? HttpPluginMetadata.decoded(from: data) else { return nil }

        var baseUrl = url.absoluteString
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = nil
            components.fragment = nil
            baseUrl = components.string ?? url.absoluteString
        }

        guard let plugin = fromMetadata(baseUrl: baseUrl, metadata: metadata) else { return nil }

        let configMap = Dictionary(uniqueKeysWithValues: plugin.configs.map { ($0.key, $0) })
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        var matchedConfigValues: [ConfigValue] = []
        for item in queryItems {
            guard let config = configMap[item.name] else { continue }
            let parsedValue = config.type.parseValue(item.value ?? "")
            matchedConfigValues.append(ConfigValue(key: item.name, value: parsedValue))
        }

        if !matchedConfigValues.isEmpty { plugin.setConfigValues(matchedConfigValues) }
        if let sourceId { plugin._id = sourceId }

        return plugin
    }

    static func fromDataModel(_ httpPluginModel: HttpPluginModel) -> HttpPlugin? {
        guard let metaData = httpPluginModel.meta.data(using: .utf8),
            let metadata = try? HttpPluginMetadata.decoded(from: metaData)
        else { return nil }

        let configValues = httpPluginModel.configValues.data(using: .utf8)
            .flatMap { try? [ConfigValue].decoded(from: $0) }

        let plugin = fromMetadata(baseUrl: httpPluginModel.baseUrl, metadata: metadata)
        plugin?._id = httpPluginModel.id

        // Update config values if they exist
        if let configValues = configValues, let plugin = plugin {
            plugin.setConfigValues(configValues)
        }

        return plugin
    }

    override class func loadStoredURL(_ id: String, in db: Database) throws -> String? {
        guard let model = try HttpPluginModel.fetchOne(db, key: id) else { return nil }
        return fromDataModel(model)?.encodedURL
    }

    override class func deleteStoredPlugin(_ id: String, in db: Database) throws {
        _ = try HttpPluginModel.filter(Column("id") == id).deleteAll(db)
    }

    override class func loadPlugins() -> [Plugin] {
        Logger.httpPlugin.debug("Loading HTTP plugins")
        guard let dbPool = DbService.shared.appDb else {
            Logger.httpPlugin.error("Database not available")
            return []
        }

        var results: [HttpPlugin] = []

        do {
            try dbPool.read { db in
                let httpPluginModels = try HttpPluginModel.fetchAll(db)

                for httpPluginModel in httpPluginModels {
                    if let httpPlugin = HttpPlugin.fromDataModel(httpPluginModel) {
                        results.append(httpPlugin)
                    }
                }
            }
        } catch { Logger.httpPlugin.error("Failed to load plugins from GRDB", error: error) }

        Task { for plugin in results { await plugin.checkForUpdates() } }
        return results
    }

    // MARK: - Private Methods

    func setup() async throws { try await getOrCreateSetupTask().value }

    private func getOrCreateSetupTask() -> Task<Void, Error> {
        setupLock.lock()
        defer { setupLock.unlock() }

        if let existingTask = setupTask { return existingTask }

        let newTask = Task {
            defer { setupTask = nil }
            try await performSetup()
        }
        setupTask = newTask
        return newTask
    }

    private func performSetup() async throws {
        // update meta
        if !isMetaUpdated {
            let metaUrl = URL(string: baseUrl)
            guard let metaUrl = metaUrl else {
                throw MankaiErrorCode.pluginHttpInvalidUrl.makeError()
            }
            let (metaData, _) = try await URLSession.shared.data(from: metaUrl)
            guard let metadata = try? HttpPluginMetadata.decoded(from: metaData) else { return }

            _name = metadata.name
            _version = metadata.version
            _description = metadata.description
            _authors = metadata.authors
            _repository = metadata.repository
            _availableGenres = metadata.availableGenres
            _authenticationEnabled = metadata.authenticationEnabled ?? false
            _capabilities = metadata.capabilities

            try PluginService.shared.savePlugin(self)
            isMetaUpdated = true
        }

        guard authenticationEnabled else { return }

        let username = _configValues["username"]?.value as? String
        let password = _configValues["password"]?.value as? String

        guard let username = username, let password = password else {
            Logger.httpPlugin.error("Username or password not set")
            throw MankaiErrorCode.pluginHttpInvalidCredentials.makeError()
        }

        if authManager.serverUrl != baseUrl { authManager.serverUrl = baseUrl }

        if authManager.username != username || !authManager.isPasswordSame(password: password) {
            try await authManager.login(username: username, password: password)
        }
    }

    // MARK: - Methods

    override func savePlugin() throws {
        Logger.httpPlugin.debug("Saving plugin: \(id)")
        guard let dbPool = DbService.shared.appDb else {
            throw MankaiErrorCode.pluginHttpDatabaseNotAvailable.makeError()
        }

        let model = try databaseModel()
        try dbPool.write { db in try model.save(db) }
    }

    override func databaseModel() throws -> any PersistableRecord {
        let metadata = HttpPluginMetadata(
            id: id, name: name, version: version, description: description, authors: authors,
            repository: repository, availableGenres: availableGenres,
            authenticationEnabled: authenticationEnabled, editorEnabled: self is EditableHttpPlugin,
            configs: configs, cooldown: cooldown,
            capabilities: _capabilities.filter { $0 != .sync && $0 != .urlEncoding })
        let metaData = try metadata.encodedData()
        guard let metaString = String(data: metaData, encoding: .utf8) else {
            throw MankaiErrorCode.pluginHttpFailedToEncodeMetaData.makeError()
        }

        // Create config values JSON
        let configValuesData = try Array(_configValues.values).encodedData()
        guard let configValuesString = String(data: configValuesData, encoding: .utf8) else {
            throw MankaiErrorCode.pluginHttpFailedToEncodeConfigValuesData.makeError()
        }

        return HttpPluginModel(
            id: id, baseUrl: baseUrl, meta: metaString, configValues: configValuesString)
    }

    override func deletePlugin() throws {
        Logger.httpPlugin.debug("Deleting plugin: \(id)")
        guard let dbPool = DbService.shared.appDb else {
            throw MankaiErrorCode.pluginHttpDatabaseNotAvailable.makeError()
        }

        let sourceId = id
        try dbPool.write { db in try Self.deleteStoredPlugin(sourceId, in: db) }
    }

    override func isOnline() async throws -> Bool {
        try await setup()
        do {
            let (_, response) = try await authManager.get(path: "/")
            return response.statusCode == 200
        } catch { return false }
    }

    override func getSuggestions(_ query: String) async throws -> [String] {
        try await setup()
        let (data, _) = try await authManager.get(path: "/suggestion", query: ["query": query])
        return try [String].decoded(from: data)
    }

    override func search(_ query: String, page: UInt, genre: Genre, status: Status, isAuthor: Bool)
        async throws -> [Manga]
    {
        try await setup()
        let (data, _) = try await authManager.get(
            path: "/search",
            query: [
                "query": query, "page": String(page), "genre": genre.rawValue,
                "status": String(status.rawValue), "isAuthor": String(isAuthor)
            ])
        return try [Manga].decoded(from: data)
    }

    override func getList(page: UInt, genre: Genre, status: Status) async throws -> [Manga] {
        try await setup()
        let (data, _) = try await authManager.get(
            path: "/manga",
            query: [
                "page": String(page), "genre": genre.rawValue, "status": String(status.rawValue)
            ])
        return try [Manga].decoded(from: data)
    }

    override func getMangas(_ ids: [String]) async throws -> [Manga] {
        try await setup()
        let body = try ids.encodedData()
        let (data, _) = try await authManager.post(path: "/manga", body: body)
        return try [Manga].decoded(from: data)
    }

    override func getMangaUpdates(_ mangas: [MangaUpdateRequest]) async throws -> [Manga] {
        guard supports(.mangaUpdates) else { return try await super.getMangaUpdates(mangas) }

        try await setup()
        let body = try mangas.encodedData()
        let (data, _) = try await authManager.post(path: "/manga/updates", body: body)
        return try [Manga].decoded(from: data)
    }

    override func getDetailedManga(_ id: String) async throws -> DetailedManga {
        try await setup()
        let (data, _) = try await authManager.get(path: "/manga/\(id)")
        return try DetailedManga.decoded(from: data)
    }

    override func getChapter(manga: DetailedManga, chapter: Chapter) async throws -> [String] {
        try await setup()
        let (data, _) = try await authManager.get(path: "/manga/\(manga.id)/chapter/\(chapter.id)")
        return try [String].decoded(from: data)
    }

    override func getImage(_ url: String) async throws -> Data {
        try await setup()

        var path = url
        if path.lowercased().hasPrefix("http") {
            if path.hasPrefix(baseUrl) {
                path = String(path.dropFirst(baseUrl.count))
            } else {
                let (data, _) = try await URLSession.shared.data(from: URL(string: url)!)
                return data
            }
        }

        // Ensure path starts with / if baseUrl doesn't end with /
        if !baseUrl.hasSuffix("/") && !path.hasPrefix("/") { path = "/" + path }

        let (data, _) = try await authManager.get(path: path)
        return data
    }

    func checkForUpdates() async {
        guard let version = version else { return }

        Logger.httpPlugin.info("Checking for updates for plugin: \(id)")

        guard let newPlugin = await HttpPlugin.fromUrl(baseUrl), let newVersion = newPlugin.version
        else {
            Logger.httpPlugin.error("Failed to fetch update for plugin: \(id)")
            return
        }

        if newVersion != version {
            Logger.httpPlugin.info(
                "Updating plugin: \(id) from version \(version) to \(newVersion)")

            do {
                _name = newPlugin._name
                _version = newPlugin._version
                _description = newPlugin._description
                _authors = newPlugin._authors
                _repository = newPlugin._repository
                _availableGenres = newPlugin._availableGenres
                _cooldown = newPlugin._cooldown
                _capabilities = newPlugin._capabilities
                _authenticationEnabled = newPlugin._authenticationEnabled

                try PluginService.shared.savePlugin(self)
                Logger.httpPlugin.info("Plugin updated successfully: \(id)")
            } catch {
                Logger.httpPlugin.error("Failed to save updated plugin: \(id)", error: error)
            }
        } else {
            Logger.httpPlugin.info("Plugin is up to date: \(id)")
        }
    }
}
