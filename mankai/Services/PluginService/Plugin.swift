//
//  Plugin.swift
//  mankai
//
//  Created by Travis XU on 21/6/2025.
//

import Foundation
import GRDB
import SwiftUI

/// A plugin type's local icon, rendered with its type or instance color.
enum PluginIcon {
    case system(String)
    case asset(String)
    case text(String)
    case folder(String)

    @MainActor @ViewBuilder func view(color: Color) -> some View {
        switch self { case .system(let name): Image(systemName: name) case .asset(let name):
            Image(name).renderingMode(.original).resizable().scaledToFit()
                .frame(width: 28, height: 28)
            case .text(let text):
                Text(verbatim: text).font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
            case .folder(let label): LabeledFolderIcon(label: label, color: color)
        }
    }
}

enum PluginStyle {
    static let palette: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown
    ]

    static func color(for id: String) -> Color {
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = (hash &<< 5) &+ hash &+ UInt64(byte) }
        let index = Int(hash % UInt64(palette.count))
        return palette[index]
    }
}

struct Cooldown: Codable {
    var `default`: Int?
    var getImage: Int?
    var getImageConcurrency: Int?
}

/// Operations and options supported by a plugin instance.
/// List and search options are opt-in and require `list` or `search`, respectively.
enum PluginCapability: String, Codable, CaseIterable {
    /// Checks source availability with `isOnline()`.
    case onlineCheck

    /// Provides query suggestions with `getSuggestions(_:)`.
    case suggestions

    // MARK: - List

    /// Lists manga with `getList(page:genre:status:sortBy:)`.
    case list

    /// Filters the list by a built-in genre.
    case listByGenre

    /// Filters the list by a source-defined genre.
    case listByCustomGenre

    /// Filters the list by publication status.
    case listByStatus

    /// Sorts the list by most recent update.
    case listByUpdateTime

    /// Sorts the list by popularity.
    case listByPopularity

    /// Sorts the list by a source-defined order.
    case listByCustomSort

    // MARK: - Search

    /// Searches manga with `search(_:page:genre:status:isAuthor:sortBy:)`.
    case search

    /// Filters search results by a built-in genre.
    case searchByGenre

    /// Filters search results by a source-defined genre.
    case searchByCustomGenre

    /// Filters search results by publication status.
    case searchByStatus

    /// Searches by author when `isAuthor` is true.
    case searchByAuthor

    /// Sorts search results by most recent update.
    case searchByUpdateTime

    /// Sorts search results by popularity.
    case searchByPopularity

    /// Sorts search results by a source-defined order.
    case searchByCustomSort

    // MARK: - Manga and Reading

    /// Retrieves full manga details with `getDetailedManga(_:)`.
    case mangaDetails

    /// Retrieves manga in batches with `getMangas(_:)` and supplies the default update check.
    case batchMangas

    /// Checks for manga updates with `getMangaUpdates(_:)`.
    case mangaUpdates

    /// Retrieves chapter pages with `getChapter(manga:chapter:)`.
    case chapter

    /// Retrieves page image data with `getImage(_:)`.
    case image

    // MARK: - Sync

    /// Exports source configuration with `encodeURL()`.
    /// Requires a stable `syncType` and transactional saves through `savePlugin(db:)`.
    case urlEncoding

    /// Enables synchronization of saved manga and reading progress.
    case sync

    // MARK: - Defaults

    /// Basic source operations assumed when capability metadata is absent.
    static let defaultCapabilities: [PluginCapability] = [
        .onlineCheck, .suggestions, .list, .search, .mangaDetails, .batchMangas, .chapter, .image
    ]
}

enum SourceStatusFilter: CaseIterable, Hashable, Sendable {
    case onGoing
    case completed

    var mangaStatus: Status {
        switch self { case .onGoing: .onGoing case .completed: .completed
        }
    }

    var rawValue: Int { mangaStatus.rawValue }
}

enum SourceGenre: Hashable, Sendable {
    case `default`
    case standard(Genre)
    case custom(String)

    static let builtIn: [SourceGenre] = Genre.allCases.map(SourceGenre.standard)

    static func options(builtIn: [Genre], custom: [String]) -> [SourceGenre] {
        var seen = Set<SourceGenre>()
        return (builtIn.map(SourceGenre.standard) + custom.map(SourceGenre.custom))
            .filter { seen.insert($0).inserted }
    }

    var value: String? {
        switch self { case .default: nil case .standard(let genre): genre.rawValue case .custom:
            "custom"
        }
    }

    var customValue: String? {
        if case .custom(let name) = self { return name }
        return nil
    }

    var listCapability: PluginCapability {
        switch self { case .default: .list case .standard: .listByGenre case .custom:
            .listByCustomGenre
        }
    }

    var searchCapability: PluginCapability {
        switch self { case .default: .search case .standard: .searchByGenre case .custom:
            .searchByCustomGenre
        }
    }
}

enum SourceSort: Hashable, Sendable {
    case `default`
    case updateTime
    case popularity
    case custom(String)

    static let builtIn: [SourceSort] = [.updateTime, .popularity]

    static func options(custom: [String]) -> [SourceSort] {
        var seen = Set<SourceSort>()
        return (builtIn + custom.map(SourceSort.custom)).filter { seen.insert($0).inserted }
    }

    var value: String? {
        switch self { case .default: nil case .updateTime: "updateTime" case .popularity:
            "popularity"
            case .custom: "custom"
        }
    }

    var customValue: String? {
        if case .custom(let name) = self { return name }
        return nil
    }

    var listCapability: PluginCapability {
        switch self { case .default: .list case .updateTime: .listByUpdateTime case .popularity:
            .listByPopularity
            case .custom: .listByCustomSort
        }
    }

    var searchCapability: PluginCapability {
        switch self { case .default: .search case .updateTime: .searchByUpdateTime case .popularity:
            .searchByPopularity
            case .custom: .searchByCustomSort
        }
    }
}

/// Behaviors supplied by a plugin type, separate from its instance capabilities.
enum PluginTypeCapability: String, Codable, CaseIterable {
    /// Requires `decodeURL(_:sourceId:)`, `loadStoredURL(_:in:)`, and `deleteStoredPlugin(_:in:)`.
    /// Decoded instances must support `savePlugin(db:)` within the caller's sync transaction.
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

    /// Stable type identifier carried in portable sync payloads.
    class var syncType: String? { nil }

    /// The localized name of this plugin type, when available.
    class var typeName: String? { nil }

    /// The default icon and background supplied by this plugin type.
    class var defaultIcon: PluginIcon { .system("puzzlepiece.extension.fill") }

    class var defaultColor: Color { .gray }

    /// The type's icon, available before an instance is configured.
    class var iconView: AnyView {
        AnyView(PluginIconView(defaultIcon: defaultIcon, color: defaultColor))
    }

    var syncType: String? { type(of: self).syncType }

    /// Restores the saved instances owned by this plugin type.
    /// Required for registered plugin types, independent of capabilities.
    class func loadPlugins() -> [Plugin] { [] }

    /// Reads the saved portable URL within the caller's database transaction.
    /// Required by `PluginTypeCapability.urlDecoding` to compare saved URLs before syncing changes.
    class func loadStoredURL(_ id: String, in db: Database) throws -> String? { nil }

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

    var typeName: String? { type(of: self).typeName }

    var version: String? { nil }

    var tags: [String] { typeName.map { [$0] } ?? [] }

    var description: String? { nil }

    var authors: [String] { [] }

    var repository: String? { nil }

    var icon: String? { nil }

    /// The custom icon when available, otherwise this plugin type's default.
    var iconView: AnyView {
        AnyView(PluginIconView(icon: icon, defaultIcon: type(of: self).defaultIcon, color: color))
    }

    var color: Color { PluginStyle.color(for: id) }

    var homePage: String? { nil }

    /// Genres advertised by this source. Manga details can provide additional filter values.
    var availableGenres: [SourceGenre] { [] }

    /// Built-in and custom sorts before filtering by operation capability.
    var availableSorts: [SourceSort] { SourceSort.builtIn }

    var cooldown: Cooldown? { nil }

    /// Operations and options supported by this plugin instance.
    /// Sources without capability metadata use `PluginCapability.defaultCapabilities`.
    /// Advertise supported list and search options explicitly.
    var capabilities: [PluginCapability] { PluginCapability.defaultCapabilities }

    /// Type capabilities exposed by this instance, including through wrappers.
    var typeCapabilities: [PluginTypeCapability] { type(of: self).typeCapabilities }

    /// Encodes this plugin and its portable configuration.
    /// Required by `PluginCapability.urlEncoding`, callers must check that capability first.
    func encodeURL() -> String { fatalError("Not Implemented") }

    // MARK: - Abstract Methods

    /// Saves the plugin configuration or state.
    /// Required for all registered plugins, independent of capabilities, built-in plugins may do nothing.
    /// When a database is supplied, save directly without opening another database transaction.
    /// - Parameter db: The caller's database transaction, or `nil` to use the application database.
    /// - Throws: An error if saving fails.
    func savePlugin(db: Database? = nil) throws { fatalError("Not Implemented") }

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

    /// Searches for manga using the requested filters and sort order.
    /// Required by `PluginCapability.search`.
    /// The source applies supported filters and falls back to its default order for other sorts.
    /// - Parameters:
    ///   - query: The search query string.
    ///   - page: The page number for pagination.
    ///   - genre: The source genre filter, or `.default` for all genres.
    ///   - status: An optional publication status filter.
    ///   - isAuthor: Whether to search the author field instead of the title field.
    ///   - sortBy: The source-supported sort order.
    /// - Returns: A list of `Manga` objects matching the query.
    /// - Throws: An error if the search fails.
    func search(
        _: String, page _: UInt, genre _: SourceGenre = .default,
        status _: SourceStatusFilter? = nil, isAuthor _: Bool = false,
        sortBy _: SourceSort = .default
    ) async throws -> [Manga] { fatalError("Not Implemented") }

    /// Retrieves a list of manga using the requested filters and sort order.
    /// Required by `PluginCapability.list`.
    /// The source applies supported filters and falls back to its default order for other sorts.
    /// - Parameters:
    ///   - page: The page number for pagination.
    ///   - genre: The source genre filter, or `.default` for all genres.
    ///   - status: An optional publication status filter.
    ///   - sortBy: The source-supported sort order.
    /// - Returns: A list of `Manga` objects.
    /// - Throws: An error if the request fails.
    func getList(
        page _: UInt, genre _: SourceGenre = .default, status _: SourceStatusFilter? = nil,
        sortBy _: SourceSort = .default
    ) async throws -> [Manga] { fatalError("Not Implemented") }

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
    var displayTags: [String] {
        var tags = self.tags
        if let version { tags.append("v\(version)") }
        if self is Editable, !tags.contains(String(localized: "editable")) {
            tags.append(String(localized: "editable"))
        }
        return tags
    }

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

    var listGenreOptions: [SourceGenre] {
        guard supports(.list) else { return [] }
        return [.default] + availableGenres.filter { supports($0.listCapability) }
    }

    var searchGenreOptions: [SourceGenre] {
        guard supports(.search) else { return [] }
        return [.default] + availableGenres.filter { supports($0.searchCapability) }
    }

    var listSortOptions: [SourceSort] {
        guard supports(.list) else { return [] }
        return [.default] + availableSorts.filter { supports($0.listCapability) }
    }

    var searchSortOptions: [SourceSort] {
        guard supports(.search) else { return [] }
        return [.default] + availableSorts.filter { supports($0.searchCapability) }
    }

    private func supportsSort(_ sort: SourceSort, for capability: PluginCapability) -> Bool {
        supports(capability) && (sort == .default || availableSorts.contains(sort))
    }

    /// Returns whether the plugin supports listing with every requested option.
    func supportsList(
        genre: SourceGenre = .default, status: SourceStatusFilter? = nil,
        sortBy: SourceSort = .default
    ) -> Bool {
        guard supports(.list), supports(genre.listCapability) else { return false }
        if status != nil, !supports(.listByStatus) { return false }

        return supportsSort(sortBy, for: sortBy.listCapability)
    }

    /// Returns whether the plugin supports searching with every requested option.
    func supportsSearch(
        isAuthor: Bool = false, genre: SourceGenre = .default, status: SourceStatusFilter? = nil,
        sortBy: SourceSort = .default
    ) -> Bool {
        guard supports(.search), supports(genre.searchCapability) else { return false }

        if isAuthor, !supports(.searchByAuthor) { return false }
        if status != nil, !supports(.searchByStatus) { return false }

        return supportsSort(sortBy, for: sortBy.searchCapability)
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
