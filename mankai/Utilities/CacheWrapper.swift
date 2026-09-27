//
//  CacheWrapper.swift
//  mankai
//
//  Created by Travis XU on 16/2/2026.
//

import Foundation

enum CacheDirectory {
    static let regular = "regular"
    static let index = "index"
}

private enum CacheMethod: String {
    case getSuggestion
    case search
    case getList
    case getDetailedManga
    case getChapter
    case getImage
}

class CacheWrapper: Plugin {
    private final class CachedValue: @unchecked Sendable {
        let value: AnyObject

        init(_ value: AnyObject) { self.value = value }
    }

    private let plugin: Plugin

    private var configurablePlugin: any Configurable {
        guard let configurablePlugin = plugin as? any Configurable else {
            preconditionFailure("Configurable wrapper requires a configurable plugin")
        }
        return configurablePlugin
    }

    // MARK: - Cache Properties

    private let cache = NSCache<NSString, AnyObject>()
    private let requestRegistry = AsyncLoadRegistry<CachedValue>()
    private var inMemoryCacheItemCountObserver: NSObjectProtocol?

    // MARK: - Init

    static func wrapping(_ plugin: Plugin) -> Plugin {
        if let configurableEditablePlugin = plugin as? any Configurable & Editable {
            return ConfigurableEditableCacheWrapper(plugin: configurableEditablePlugin)
        }

        if let editablePlugin = plugin as? any Editable {
            return EditableCacheWrapper(plugin: editablePlugin)
        }

        if plugin is any Configurable { return ConfigurableCacheWrapper(plugin: plugin) }

        return CacheWrapper(plugin: plugin)
    }

    fileprivate init(plugin: Plugin) {
        // We set the wrapped plugin heavily relying on delegation
        self.plugin = plugin
        super.init()
        updateInMemoryCacheItemCount()
        inMemoryCacheItemCountObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.updateInMemoryCacheItemCount() }
        }
        Logger.cacheWrapper.debug("Initialized CacheWrapper for plugin: \(plugin.id)")
    }

    isolated deinit {
        if let inMemoryCacheItemCountObserver {
            NotificationCenter.default.removeObserver(inMemoryCacheItemCountObserver)
        }
    }

    // MARK: - Metadata Delegation

    override var id: String { plugin.id }

    override var name: String? { plugin.name }

    override var version: String? { plugin.version }

    override var tags: [String] { plugin.tags }

    override var description: String? { plugin.description }

    override var authors: [String] { plugin.authors }

    override var repository: String? { plugin.repository }

    override var availableGenres: [Genre] { plugin.availableGenres }

    var configs: [Config] { configurablePlugin.configs }

    override var cooldown: Cooldown? { plugin.cooldown }

    override var capabilities: [PluginCapability] { plugin.capabilities }

    override var shouldSync: Bool { plugin.shouldSync }

    override var shouldCache: Bool { plugin.shouldCache }

    override var canDownload: Bool { plugin.canDownload }

    override var canUpdate: Bool { plugin.canUpdate }

    // MARK: - Configs Delegation

    var configValues: [ConfigValue] { configurablePlugin.configValues }

    func getConfig(_ key: String) -> Any { configurablePlugin.getConfig(key) }

    func setConfig(key: String, value: Any) throws {
        defer { objectWillChange.send() }
        try configurablePlugin.setConfig(key: key, value: value)
    }

    func resetConfigs() throws {
        defer { objectWillChange.send() }
        try configurablePlugin.resetConfigs()
    }

    // MARK: - Methods Delegation (Non-cached)

    override func savePlugin() throws { try plugin.savePlugin() }

    override func deletePlugin() throws { try plugin.deletePlugin() }

    override func isOnline() async throws -> Bool { return try await plugin.isOnline() }

    override func getMangas(_ ids: [String]) async throws -> [Manga] {
        return try await plugin.getMangas(ids)
    }

    override func getMangaUpdates(_ mangas: [MangaUpdateRequest]) async throws -> [Manga] {
        return try await plugin.getMangaUpdates(mangas)
    }

    // MARK: - Caching Logic

    private func updateInMemoryCacheItemCount() {
        var itemCount = UserDefaults.standard.integer(
            forKey: SettingsKey.inMemoryCacheItemCount.rawValue)
        itemCount = itemCount > 0 ? itemCount : SettingsDefaults.inMemoryCacheItemCount

        guard cache.countLimit != itemCount else { return }
        cache.countLimit = itemCount
    }

    private func getCacheKey(for method: CacheMethod, with parameters: [String]) -> String {
        // URL-encode parameters to handle special characters
        let encodedParams = parameters.map { param in
            param.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? param
        }
        let paramString = encodedParams.joined(separator: "+")
        return "\(id)+\(method.rawValue)+\(paramString)"
    }

    private func getCachedData<T>(for key: String, as _: T.Type) -> T? {
        guard let data = cache.object(forKey: key as NSString) else {
            Logger.cacheWrapper.debug("Cache miss for key: \(key)")
            return nil
        }

        Logger.cacheWrapper.debug("Cache hit for key: \(key)")
        return data as? T
    }

    private func setCachedData(_ data: Any, for key: String) {
        Logger.cacheWrapper.debug("Setting cache for key: \(key)")
        cache.setObject(data as AnyObject, forKey: key as NSString)
    }

    private func getOrLoadCachedData<T>(
        for key: String, load: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if let cachedData = getCachedData(for: key, as: T.self) { return cachedData }

        let data = try await requestRegistry.value(for: key) { @MainActor [self] in
            if let cachedData = getCachedData(for: key, as: T.self) {
                return CachedValue(cachedData as AnyObject)
            }

            let data = try await load()
            setCachedData(data, for: key)
            return CachedValue(data as AnyObject)
        }

        guard let typedData = data.value as? T else {
            preconditionFailure("Cached request type mismatch for key: \(key)")
        }
        return typedData
    }

    func clearAllCache() {
        Logger.cacheWrapper.info("Clearing all in-memory cache")
        cache.removeAllObjects()

        objectWillChange.send()
    }

    // MARK: - Methods (Cached)

    override func getSuggestions(_ query: String) async throws -> [String] {
        let cacheKey = getCacheKey(for: .getSuggestion, with: [query])
        return try await getOrLoadCachedData(for: cacheKey) {
            try await self.plugin.getSuggestions(query)
        }
    }

    override func search(_ query: String, page: UInt, genre: Genre, status: Status, isAuthor: Bool)
        async throws -> [Manga]
    {
        let cacheKey = getCacheKey(
            for: .search,
            with: [query, String(page), genre.rawValue, String(status.rawValue), String(isAuthor)])
        return try await getOrLoadCachedData(for: cacheKey) {
            try await self.plugin.search(
                query, page: page, genre: genre, status: status, isAuthor: isAuthor)
        }
    }

    override func getList(page: UInt, genre: Genre, status: Status) async throws -> [Manga] {
        let cacheKey = getCacheKey(
            for: .getList, with: [String(page), genre.rawValue, String(status.rawValue)])
        return try await getOrLoadCachedData(for: cacheKey) {
            try await self.plugin.getList(page: page, genre: genre, status: status)
        }
    }

    override func getDetailedManga(_ id: String) async throws -> DetailedManga {
        let cacheKey = getCacheKey(for: .getDetailedManga, with: [id])
        return try await getOrLoadCachedData(for: cacheKey) {
            try await self.plugin.getDetailedManga(id)
        }
    }

    override func getChapter(manga: DetailedManga, chapter: Chapter) async throws -> [String] {
        let cacheKey = getCacheKey(for: .getChapter, with: [manga.id, chapter.id])
        return try await getOrLoadCachedData(for: cacheKey) {
            try await self.plugin.getChapter(manga: manga, chapter: chapter)
        }
    }

    override func getImage(_ url: String) async throws -> Data {
        let cacheKey = getCacheKey(for: .getImage, with: [url])
        Logger.cacheWrapper.debug("Checking disk cache for image: \(url)")

        return try await ImageCacheManager.shared.image(for: cacheKey, pluginID: id) {
            try await self.plugin.getImage(url)
        }
    }
}

private final class ConfigurableCacheWrapper: CacheWrapper, Configurable {}

private class EditableCacheWrapper: CacheWrapper, Editable {
    private let editablePlugin: any Editable

    init(plugin: any Editable) {
        editablePlugin = plugin
        super.init(plugin: plugin)
    }

    func upsertManga(_ manga: EditableManga) async throws -> String {
        let id = try await editablePlugin.upsertManga(manga)
        clearAllCache()
        return id
    }

    func deleteManga(_ mangaId: String) async throws {
        try await editablePlugin.deleteManga(mangaId)
        clearAllCache()
    }

    func upsertCover(mangaId: String, image: Data) async throws {
        try await editablePlugin.upsertCover(mangaId: mangaId, image: image)
        clearAllCache()
    }

    func upsertChapterGroup(_ group: EditableChapterGroup) async throws {
        try await editablePlugin.upsertChapterGroup(group)
        clearAllCache()
    }

    func deleteChapterGroup(id: String) async throws {
        try await editablePlugin.deleteChapterGroup(id: id)
        clearAllCache()
    }

    func getChapters(groupId: String) async throws -> [Chapter] {
        try await editablePlugin.getChapters(groupId: groupId)
    }

    func upsertChapter(_ chapter: EditableChapter) async throws {
        try await editablePlugin.upsertChapter(chapter)
        clearAllCache()
    }

    func deleteChapter(id: String) async throws {
        try await editablePlugin.deleteChapter(id: id)
        clearAllCache()
    }

    func arrangeChapterOrder(ids: [String]) async throws {
        try await editablePlugin.arrangeChapterOrder(ids: ids)
        clearAllCache()
    }

    func addImages(chapterId: String, images: [Data]) async throws {
        try await editablePlugin.addImages(chapterId: chapterId, images: images)
        clearAllCache()
    }

    func deleteImages(ids: [String]) async throws {
        try await editablePlugin.deleteImages(ids: ids)
        clearAllCache()
    }

    func arrangeImageOrder(ids: [String]) async throws {
        try await editablePlugin.arrangeImageOrder(ids: ids)
        clearAllCache()
    }
}

private final class ConfigurableEditableCacheWrapper: EditableCacheWrapper, Configurable {}
