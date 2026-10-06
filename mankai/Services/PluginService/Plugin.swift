//
//  Plugin.swift
//  mankai
//
//  Created by Travis XU on 21/6/2025.
//

import Foundation
import GRDB

struct Cooldown: Codable {
    var `default`: Int?
    var getImage: Int?
    var getImageConcurrency: Int?
}

/// Features supported by a plugin instance.
enum PluginCapability: String, Codable, CaseIterable {
    /// Requires `isOnline()`.
    case onlineCheck

    /// Requires `getSuggestions(_:)`.
    case suggestions

    /// Requires `getList(page:genre:status:)`.
    case list

    /// Requires `list` and genre filtering in `getList(page:genre:status:)`.
    case listByGenre

    /// Requires `list` and status filtering in `getList(page:genre:status:)`.
    case listByStatus

    /// Requires `search(_:page:genre:status:isAuthor:)`.
    case search

    /// Requires `search` and genre filtering in `search(_:page:genre:status:isAuthor:)`.
    case searchByGenre

    /// Requires `search` and status filtering in `search(_:page:genre:status:isAuthor:)`.
    case searchByStatus

    /// Requires `search` and author searches with `isAuthor == true`.
    case searchByAuthor

    /// Requires `getDetailedManga(_:)`.
    case mangaDetails

    /// Requires `getMangas(_:)`, also supplies the default `getMangaUpdates(_:)` implementation.
    case batchMangas

    /// Requires `getMangaUpdates(_:)`, its default implementation requires `batchMangas`.
    case mangaUpdates

    /// Requires `getChapter(manga:chapter:)`.
    case chapter

    /// Requires `getImage(_:)`.
    case image

    /// Requires `encodeURL()` to return the instance's portable configuration as a URL.
    case urlEncoding

    /// Enables manga and reading progress synchronization, requires no additional plugin methods.
    case sync

    static var defaultCapabilities: [PluginCapability] {
        allCases.filter { $0 != .mangaUpdates && $0 != .urlEncoding }
    }
}

/// Behaviors supplied by a plugin type, separate from its instance capabilities.
enum PluginTypeCapability: String, Codable, CaseIterable {
    /// Requires `decodeURL(_:sourceId:)`, `loadStoredPlugin(_:in:)`, and `deleteStoredPlugin(_:in:)`.
    /// Decoded instances must implement `databaseModel()` for sync transactions.
    case urlDecoding

    /// Caches responses from supported operations, requires no additional plugin methods.
    case cache

    /// Requires `PluginCapability.chapter` and `PluginCapability.image` for offline downloads.
    /// These capabilities require `getChapter(manga:chapter:)` and `getImage(_:)`.
    case download
}

@MainActor class Plugin: Identifiable, ObservableObject {
    init() {}

    /// Capabilities available before an instance has been loaded or decoded.
    class var typeCapabilities: [PluginTypeCapability] { [.download] }

    /// Restores the saved instances owned by this plugin type.
    /// Required for registered plugin types, independent of capabilities.
    class func loadPlugins() -> [Plugin] { [] }

    /// Restores one saved instance within the caller's database transaction.
    /// Required by `PluginTypeCapability.urlDecoding` to compare saved URLs before syncing changes.
    class func loadStoredPlugin(_ id: String, in db: Database) throws -> Plugin? { nil }

    /// Deletes only this type's saved configuration within the caller's transaction.
    /// Required by `PluginTypeCapability.urlDecoding` for synced replacements and deletions.
    class func deleteStoredPlugin(_ id: String, in db: Database) throws {}

    /// Decodes a supported URL, or returns `nil` when this type does not recognize it.
    /// Required by `PluginTypeCapability.urlDecoding`.
    class func decodeURL(_ url: String, sourceId: String? = nil) async -> Plugin? { nil }

    // MARK: - Metadata

    /// The unique identifier of the plugin.
    /// Required for all registered plugins, independent of capabilities.
    /// - Returns: A unique string identifier.
    var id: String { fatalError("Not Implemented") }

    var name: String? { nil }

    var version: String? { nil }

    var tags: [String] { [] }

    var description: String? { nil }

    var authors: [String] { [] }

    var repository: String? { nil }

    var availableGenres: [Genre] { [] }

    var cooldown: Cooldown? { nil }

    /// Features supported by this plugin instance.
    ///
    /// Plugins that do not provide capability metadata support every non-opt-in operation.
    /// Advertise a capability only when its required methods are implemented and available.
    /// Filter capabilities also require their base `list` or `search` capability.
    var capabilities: [PluginCapability] { PluginCapability.defaultCapabilities }

    /// Type capabilities exposed by this instance, including through wrappers.
    var typeCapabilities: [PluginTypeCapability] { type(of: self).typeCapabilities }

    /// Encodes this plugin and its portable configuration.
    /// Required by `PluginCapability.urlEncoding`, callers must check that capability first.
    func encodeURL() -> String { fatalError("Not Implemented") }

    // MARK: - Abstract Methods

    /// Saves the plugin configuration or state.
    /// Required for all registered plugins, independent of capabilities, built-in plugins may do nothing.
    /// - Throws: An error if saving fails.
    func savePlugin() throws { fatalError("Not Implemented") }

    /// Returns the local record for a decoded plugin before it is saved in a sync transaction.
    /// Required on instances decoded by a `PluginTypeCapability.urlDecoding` plugin type.
    func databaseModel() throws -> any PersistableRecord { fatalError("Not Implemented") }

    /// Deletes the plugin and cleans up resources.
    /// Required for all registered plugins, independent of capabilities, built-in plugins may do nothing.
    /// - Throws: An error if deletion fails.
    func deletePlugin() throws { fatalError("Not Implemented") }

    /// Checks if the plugin is currently online and reachable.
    /// Required by `PluginCapability.onlineCheck`.
    /// - Returns: `true` if online, `false` otherwise.
    /// - Throws: An error if the check fails.
    func isOnline() async throws -> Bool { fatalError("Not Implemented") }

    /// Gets search suggestions based on a query.
    /// Required by `PluginCapability.suggestions`.
    /// - Parameter query: The search query string.
    /// - Returns: A list of suggested search terms.
    /// - Throws: An error if the request fails.
    func getSuggestions(_: String) async throws -> [String] { fatalError("Not Implemented") }

    /// Searches for manga based on a query.
    /// Required by `PluginCapability.search`.
    /// `searchByGenre`, `searchByStatus`, and `searchByAuthor` require handling the corresponding filters.
    /// - Parameters:
    ///   - query: The search query string.
    ///   - page: The page number for pagination.
    ///   - genre: The genre to filter by.
    ///   - status: The status to filter by.
    ///   - isAuthor: Whether to search the author field instead of the title field.
    /// - Returns: A list of `Manga` objects matching the query.
    /// - Throws: An error if the search fails.
    func search(_: String, page _: UInt, genre _: Genre, status _: Status, isAuthor _: Bool = false)
        async throws -> [Manga]
    { fatalError("Not Implemented") }

    /// Retrieves a list of manga based on optional filters.
    /// Required by `PluginCapability.list`.
    /// `listByGenre` and `listByStatus` require handling the corresponding filters.
    /// - Parameters:
    ///   - page: The page number for pagination.
    ///   - genre: The genre to filter by.
    ///   - status: The status to filter by.
    /// - Returns: A list of `Manga` objects.
    /// - Throws: An error if the request fails.
    func getList(page _: UInt, genre _: Genre, status _: Status) async throws -> [Manga] {
        fatalError("Not Implemented")
    }

    /// Retrieves details for multiple mangas by their IDs.
    /// Required by `PluginCapability.batchMangas` and used by the default `getMangaUpdates(_:)`.
    /// - Parameter ids: A list of manga IDs.
    /// - Returns: A list of `Manga` objects.
    /// - Throws: An error if the request fails.
    func getMangas(_: [String]) async throws -> [Manga] { fatalError("Not Implemented") }

    /// Retrieves current manga metadata and whether each manga should be marked as updated.
    /// Called for `PluginCapability.mangaUpdates` or the `batchMangas` update fallback.
    /// The default implementation delegates to `getMangas(_:)`.
    /// Plugins advertising `mangaUpdates` without `batchMangas` must override this method.
    /// - Parameter mangas: Manga IDs paired with their last known latest chapters.
    /// - Returns: Manga values whose `updates` flag is always populated.
    /// - Throws: An error if the request fails.
    func getMangaUpdates(_ mangas: [MangaUpdateRequest]) async throws -> [Manga] {
        let latestChapters = Dictionary(
            uniqueKeysWithValues: mangas.map { ($0.id, $0.latestChapter.id) })
        return try await getMangas(mangas.map(\.id))
            .map { manga in
                var manga = manga
                if let latestChapter = manga.latestChapter,
                    let previousChapterId = latestChapters[manga.id]
                {
                    manga.updates = latestChapter.id != previousChapterId
                } else {
                    manga.updates = false
                }
                return manga
            }
    }

    /// Retrieves detailed information for a specific manga.
    /// Required by `PluginCapability.mangaDetails`.
    /// - Parameter id: The ID of the manga.
    /// - Returns: A `DetailedManga` object.
    /// - Throws: An error if the request fails.
    func getDetailedManga(_: String) async throws -> DetailedManga { fatalError("Not Implemented") }

    /// Retrieves the list of image URLs for a specific chapter.
    /// Required by `PluginCapability.chapter` and used for `PluginTypeCapability.download`.
    /// - Parameters:
    ///   - manga: The manga containing the chapter.
    ///   - chapter: The chapter to retrieve images for.
    /// - Returns: A list of image URLs.
    /// - Throws: An error if the request fails.
    func getChapter(manga _: DetailedManga, chapter _: Chapter) async throws -> [String] {
        fatalError("Not Implemented")
    }

    /// Retrieves image data from a URL.
    /// Required by `PluginCapability.image` and used for `PluginTypeCapability.download`.
    /// - Parameter url: The URL of the image.
    /// - Returns: The image data.
    /// - Throws: An error if the request fails.
    func getImage(_: String) async throws -> Data { fatalError("Not Implemented") }
}

extension Plugin {
    func configuredURL(_ url: String, values: [ConfigValue]) -> String? {
        guard var components = URLComponents(string: url) else { return nil }
        let keys = Set(values.map(\.key))
        var items = (components.queryItems ?? []).filter { !keys.contains($0.name) }
        items += values.sorted { $0.key < $1.key }
            .compactMap { value in
                guard !(value.value is NSNull) else { return nil }
                return URLQueryItem(name: value.key, value: String(describing: value.value))
            }
        components.queryItems = items.isEmpty ? nil : items
        return components.string
    }

    /// Returns whether the plugin advertises support for a capability.
    func supports(_ capability: PluginCapability) -> Bool { capabilities.contains(capability) }

    /// Returns whether the plugin can service a list request with the supplied filters.
    /// Filter capabilities augment, rather than replace, the base list capability.
    func supportsList(genre: Genre = .all, status: Status = .any) -> Bool {
        guard supports(.list) else { return false }

        if genre != .all, !supports(.listByGenre) { return false }
        if status != .any, !supports(.listByStatus) { return false }

        return true
    }

    /// Returns whether the plugin can service a search request with the supplied filters.
    /// Filter capabilities augment, rather than replace, the base search capability.
    func supportsSearch(isAuthor: Bool = false, genre: Genre = .all, status: Status = .any) -> Bool
    {
        guard supports(.search) else { return false }

        if isAuthor, !supports(.searchByAuthor) { return false }
        if genre != .all, !supports(.searchByGenre) { return false }
        if status != .any, !supports(.searchByStatus) { return false }

        return true
    }

    /// Whether this plugin can check saved manga for updates.
    /// Requires `mangaUpdates` or `batchMangas`, batch support uses the default update implementation.
    var supportsUpdates: Bool {
        capabilities.contains(.batchMangas) || capabilities.contains(.mangaUpdates)
    }

    /// Whether the source can resolve chapters and fetch their images.
    var supportsRemoteReading: Bool { supports(.chapter) && supports(.image) }

    /// Whether new offline downloads can be created from this source.
    /// Requires `PluginTypeCapability.download` plus the instance's `chapter` and `image` capabilities.
    var supportsDownloads: Bool { typeCapabilities.contains(.download) && supportsRemoteReading }

    /// Retrieves one manga through `getMangas(_:)`, requires `PluginCapability.batchMangas`.
    func getManga(id: String) async throws -> Manga {
        let mangas = try await getMangas([id])

        if let manga = mangas.first {
            return manga
        } else {
            throw MankaiErrorCode.pluginMangaNotFound.makeError()
        }
    }
}
