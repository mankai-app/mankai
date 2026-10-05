//
//  Plugin.swift
//  mankai
//
//  Created by Travis XU on 21/6/2025.
//

import Foundation

struct Cooldown: Codable {
    var `default`: Int?
    var getImage: Int?
    var getImageConcurrency: Int?
}

/// Features that a plugin can support.
enum PluginCapability: String, Codable, CaseIterable {
    case onlineCheck
    case suggestions
    case list
    case listByGenre
    case listByStatus
    case search
    case searchByGenre
    case searchByStatus
    case searchByAuthor
    case mangaDetails
    case batchMangas
    case mangaUpdates
    case chapter
    case image

    static var defaultCapabilities: [PluginCapability] { allCases.filter { $0 != .mangaUpdates } }
}

@MainActor class Plugin: Identifiable, ObservableObject {
    init() {}

    // MARK: - Metadata

    /// The unique identifier of the plugin.
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

    /// Operations supported by the plugin.
    ///
    /// Plugins that do not provide capability metadata support every non-opt-in operation.
    /// Plugins can override this with a smaller list.
    var capabilities: [PluginCapability] { PluginCapability.defaultCapabilities }

    /// Whether manga sourced from this plugin should be synced across devices.
    var shouldSync: Bool { true }

    /// A type-prefixed URL used to sync this plugin and its portable configuration.
    var syncURL: String? { nil }

    /// Whether response data from this plugin should be cached.
    var shouldCache: Bool { false }

    /// Whether manga sourced from this plugin can be downloaded for offline access.
    var canDownload: Bool { true }

    /// Whether this plugin can check saved manga for updates.
    var canUpdate: Bool {
        capabilities.contains(.batchMangas) || capabilities.contains(.mangaUpdates)
    }

    // MARK: - Abstract Methods

    /// Saves the plugin configuration or state.
    /// - Throws: An error if saving fails.
    func savePlugin() throws { fatalError("Not Implemented") }

    /// Deletes the plugin and cleans up resources.
    /// - Throws: An error if deletion fails.
    func deletePlugin() throws { fatalError("Not Implemented") }

    /// Checks if the plugin is currently online and reachable.
    /// - Returns: `true` if online, `false` otherwise.
    /// - Throws: An error if the check fails.
    func isOnline() async throws -> Bool { fatalError("Not Implemented") }

    /// Gets search suggestions based on a query.
    /// - Parameter query: The search query string.
    /// - Returns: A list of suggested search terms.
    /// - Throws: An error if the request fails.
    func getSuggestions(_: String) async throws -> [String] { fatalError("Not Implemented") }

    /// Searches for manga based on a query.
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
    /// - Parameter ids: A list of manga IDs.
    /// - Returns: A list of `Manga` objects.
    /// - Throws: An error if the request fails.
    func getMangas(_: [String]) async throws -> [Manga] { fatalError("Not Implemented") }

    /// Retrieves current manga metadata and whether each manga should be marked as updated.
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
    /// - Parameter id: The ID of the manga.
    /// - Returns: A `DetailedManga` object.
    /// - Throws: An error if the request fails.
    func getDetailedManga(_: String) async throws -> DetailedManga { fatalError("Not Implemented") }

    /// Retrieves the list of image URLs for a specific chapter.
    /// - Parameters:
    ///   - manga: The manga containing the chapter.
    ///   - chapter: The chapter to retrieve images for.
    /// - Returns: A list of image URLs.
    /// - Throws: An error if the request fails.
    func getChapter(manga _: DetailedManga, chapter _: Chapter) async throws -> [String] {
        fatalError("Not Implemented")
    }

    /// Retrieves image data from a URL.
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

    /// Whether the source can resolve chapters and fetch their images.
    var supportsRemoteReading: Bool { supports(.chapter) && supports(.image) }

    /// Whether new offline downloads can be created from this source.
    var supportsDownloads: Bool { canDownload && supportsRemoteReading }

    func getManga(id: String) async throws -> Manga {
        let mangas = try await getMangas([id])

        if let manga = mangas.first {
            return manga
        } else {
            throw MankaiErrorCode.pluginMangaNotFound.makeError()
        }
    }
}
