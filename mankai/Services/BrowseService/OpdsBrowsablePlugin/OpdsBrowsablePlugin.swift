//
//  OpdsBrowsablePlugin.swift
//  mankai
//
//  Created by Travis XU on 19/8/2026.
//

import CryptoKit
import Foundation
import GRDB
import SwiftUI

/// OPDS support is based on the [OPDS 1.2 specification](https://specs.opds.io/opds-1.2) and the [OPDS Page Streaming Extension 1.2 specification](https://anansi-project.github.io/docs/opds-pse/specs/v1.2).

struct OpdsConnectionConfiguration: Sendable {
    let catalogURL: URL
    var username: String?
    var password: String?

    init(catalogURL: String, username: String? = nil, password: String? = nil) throws {
        guard
            let normalizedURL = URL.normalizedHTTPURL(
                catalogURL, allowsCredentials: true, allowsQuery: true, allowsFragment: true)
        else { throw URLError(.badURL) }

        self.catalogURL = normalizedURL
        self.username = username.trimmed
        self.password = password.trimmed
    }
}

actor OpdsSession {
    nonisolated let configuration: OpdsConnectionConfiguration

    private let urlSession: URLSession

    init(configuration: OpdsConnectionConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    func get(url: URL) async throws -> OpdsFeed {
        let data = try await data(for: url)
        return try OpdsParser.parse(data, baseURL: url)
    }

    func download(url: URL) async throws -> Data { try await data(for: url) }

    private func data(for url: URL) async throws -> Data {
        var request = URLRequest(url: url)

        if let username = configuration.username {
            let credentials = "\(username):\(configuration.password ?? "")"
            let encodedCredentials = Data(credentials.utf8).base64EncodedString()
            request.setValue("Basic \(encodedCredentials)", forHTTPHeaderField: "Authorization")
        }

        let (data, _) = try await urlSession.data(for: request)
        return data
    }
}

final class OpdsBrowsablePlugin: Plugin, Browsable, LocalBrowsablePluginConvertible {
    private static let pseFileType = "pse"
    private static let imagePrefix = "opds-image:"
    private static let pseMaxWidth = 2000

    private var _id: String
    var configuration: OpdsConnectionConfiguration {
        didSet { session = OpdsSession(configuration: configuration) }
    }
    var displayName: String?
    private var _shouldSync: Bool
    private var session: OpdsSession
    private let parsers: [String: Parser]
    private let mimeTypes: [String: Parser]

    private struct RegularFileInfo {
        let fileName: String
        let parser: Parser
    }

    private var temporaryDirectory: URL {
        let cacheName = SHA256.hash(data: Data(_id.utf8)).map { String(format: "%02x", $0) }
            .joined()
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("opds", isDirectory: true)
            .appendingPathComponent(cacheName, isDirectory: true)
    }

    override var id: String { _id }

    override var name: String? {
        displayName ?? configuration.catalogURL.host ?? configuration.catalogURL.absoluteString
    }

    override var shouldSync: Bool { _shouldSync }

    func convertToLocalPlugin() {
        _id = UUID().uuidString
        _shouldSync = false
    }

    override var availableGenres: [Genre] { Genre.allCases }

    override var capabilities: [PluginCapability] {
        [.onlineCheck, .mangaDetails, .batchMangas, .chapter, .image]
    }

    override var canDownload: Bool { false }

    var icon: AnyView { AnyView(Image(systemName: "books.vertical.fill")) }

    var color: Color { BrowsablePluginStyle.color(for: _id) }

    convenience init(session: OpdsSession, name: String?) async throws {
        let rootCatalog = try await session.get(url: session.configuration.catalogURL)
        let id = rootCatalog.metadata.id ?? UUID().uuidString

        try self.init(
            id: id, name: name, configuration: session.configuration, session: session,
            shouldSync: rootCatalog.metadata.id != nil)
    }

    init(
        id: String, name: String?, configuration: OpdsConnectionConfiguration,
        session: OpdsSession? = nil, shouldSync: Bool = true
    ) throws {
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { throw MankaiErrorCode.browseOpdsInvalidPlugin.makeError() }

        self._id = trimmedId
        self.displayName = name.trimmed
        self._shouldSync = shouldSync
        self.configuration = configuration
        self.session = session ?? OpdsSession(configuration: configuration)

        let allParsers: [Parser] = [CbzParser(), CbrParser(), PdfParser(), EpubParser()]
        var parsers: [String: Parser] = [:]
        for parser in allParsers {
            for ext in parser.supportedExtensions { parsers[ext.lowercased()] = parser }
        }
        self.parsers = parsers

        var mimeTypes: [String: Parser] = [:]
        for parser in allParsers {
            for mimeType in parser.supportedMimeTypes { mimeTypes[mimeType.lowercased()] = parser }
        }
        self.mimeTypes = mimeTypes

        super.init()
        try BrowsableFileUtilities.clearDirectoryIfPresent(at: temporaryDirectory)
    }

    isolated deinit { try? BrowsableFileUtilities.clearDirectoryIfPresent(at: temporaryDirectory) }

    func getEntities(path: String?) async throws -> [Entity] {
        let catalogURL: URL
        if let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            guard let url = URL(string: path) else { throw URLError(.badURL) }
            catalogURL = url
        } else {
            catalogURL = configuration.catalogURL
        }

        Logger.opdsBrowsablePlugin.debug("Getting OPDS entities from: \(catalogURL)")
        let feed = try await session.get(url: catalogURL)
        var books: [OpdsBookEntry] = []
        var entities: [Entity] = []

        for entry in feed.entries {
            switch entry { case .navigation(let navigation):
                let fallbackName =
                    navigation.url.lastPathComponent.isEmpty
                    ? navigation.url.absoluteString : navigation.url.lastPathComponent
                let displayName = navigation.title.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
                entities.append(
                    Entity(
                        path: navigation.url.absoluteString, displayName: displayName,
                        name: displayName, type: .directory))
                case .book(let book):
                    let fileName: String
                    let fileType: String
                    switch book.mediaType { case .regular(let url, let type):
                        guard let regularFile = regularFileInfo(url: url, type: type) else {
                            continue
                        }
                        fileName = regularFile.fileName
                        fileType = regularFile.parser.id
                        case .pse(let urlTemplate, _):
                            fileName = urlTemplate.lastPathComponent
                            fileType = Self.pseFileType
                    }

                    books.append(book)
                    entities.append(
                        Entity(
                            path: book.id, displayName: book.title ?? fileName, name: fileName,
                            type: .book(fileType: fileType)))
            }
        }

        try await store(books: books)
        return entities
    }

    func parseFile(path: String, fileType _: String) async throws -> DetailedManga {
        try await detailedManga(for: path)
    }

    func absoluteURL(for path: String?) -> URL? { nil }

    static func loadPlugins() -> [OpdsBrowsablePlugin] {
        Logger.opdsBrowsablePlugin.debug("Loading OPDS browsable plugins")
        guard let dbPool = DbService.shared.appDb else {
            Logger.opdsBrowsablePlugin.error("Database not available")
            return []
        }

        let models: [OpdsBrowsablePluginModel]
        do { models = try dbPool.read { db in try OpdsBrowsablePluginModel.fetchAll(db) } } catch {
            Logger.opdsBrowsablePlugin.error(
                "Failed to fetch OpdsBrowsablePluginModels", error: error)
            return []
        }

        var results: [OpdsBrowsablePlugin] = []
        for model in models {
            do {
                let configuration = try OpdsConnectionConfiguration(
                    catalogURL: model.catalogURL, username: model.username, password: model.password
                )
                try results.append(
                    OpdsBrowsablePlugin(
                        id: model.id, name: model.name, configuration: configuration,
                        shouldSync: model.shouldSync))
            } catch {
                Logger.opdsBrowsablePlugin.error(
                    "Failed to load OPDS plugin \(model.id)", error: error)
            }
        }
        return results
    }

    override func savePlugin() throws {
        Logger.opdsBrowsablePlugin.debug("Saving OPDS plugin: \(id)")
        guard let db = DbService.shared.appDb else {
            throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
        }

        let model = OpdsBrowsablePluginModel(
            id: id, name: displayName, catalogURL: configuration.catalogURL.absoluteString,
            username: configuration.username, password: configuration.password,
            shouldSync: _shouldSync)
        try db.write { db in try model.save(db) }
    }

    override func deletePlugin() throws {
        Logger.opdsBrowsablePlugin.debug("Deleting OPDS plugin: \(id)")
        guard let appDb = DbService.shared.appDb,
            let opdsDb = DbService.shared.openOpdsBrowsablePluginDb()
        else { throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError() }

        _ = try opdsDb.write { db in
            try OpdsBrowsableBookModel.filter(Column("pluginId") == id).deleteAll(db)
        }
        _ = try appDb.write { db in try OpdsBrowsablePluginModel.deleteOne(db, key: id) }

        try BrowsableFileUtilities.clearDirectoryIfPresent(at: temporaryDirectory)
    }

    override func isOnline() async throws -> Bool {
        do {
            _ = try await session.get(url: configuration.catalogURL)
            return true
        } catch { return false }
    }

    override func getMangas(_ ids: [String]) async throws -> [Manga] {
        let books = try await cachedBooks(for: ids)
        return books.map { detailedManga(from: $0).toManga() }
    }

    override func getDetailedManga(_ id: String) async throws -> DetailedManga {
        try await detailedManga(for: id)
    }

    override func getChapter(manga: DetailedManga, chapter: Chapter) async throws -> [String] {
        guard let book = try await cachedBook(for: manga.id) else {
            throw MankaiErrorCode.pluginMangaNotFound.makeError()
        }

        let images: [String]
        switch book.mediaType { case .pse(let urlTemplate, let pageCount):
            images = (0..<pageCount)
                .map {
                    urlTemplate.absoluteString
                        .replacingOccurrences(
                            of: "%7BpageNumber%7D", with: String($0), options: .caseInsensitive
                        )
                        .replacingOccurrences(of: "{pageNumber}", with: String($0))
                        .replacingOccurrences(
                            of: "%7BmaxWidth%7D", with: String(Self.pseMaxWidth),
                            options: .caseInsensitive
                        )
                        .replacingOccurrences(of: "{maxWidth}", with: String(Self.pseMaxWidth))
                }
            case .regular(let url, let type):
                guard let regularFile = regularFileInfo(url: url, type: type) else {
                    throw MankaiErrorCode.browseFilesystemParserNotFound.makeError()
                }
                let fileName = regularFile.fileName
                let parser = regularFile.parser
                let file = OpdsParserFile(
                    cacheKey: book.id, remoteURL: url, fileName: fileName, session: session,
                    temporaryDirectory: temporaryDirectory)
                let parsedManga = try await parser.parse(file: file)
                images = try await parser.parseChapter(
                    manga: parsedManga, chapter: chapter, file: file)
        }

        let encodedBookId = Data(book.id.utf8).base64EncodedString()
        return images.map {
            "\(Self.imagePrefix)\(encodedBookId):\(Data($0.utf8).base64EncodedString())"
        }
    }

    override func getImage(_ path: String) async throws -> Data {
        guard path.hasPrefix(Self.imagePrefix) else {
            guard let url = URL(string: path) else { throw URLError(.badURL) }
            return try await session.download(url: url)
        }

        let encodedRoute = path.dropFirst(Self.imagePrefix.count)
        guard let separator = encodedRoute.firstIndex(of: ":"),
            let bookIdData = Data(base64Encoded: String(encodedRoute[..<separator])),
            let bookId = String(data: bookIdData, encoding: .utf8),
            let imageData = Data(
                base64Encoded: String(encodedRoute[encodedRoute.index(after: separator)...])),
            let image = String(data: imageData, encoding: .utf8),
            let book = try await cachedBook(for: bookId)
        else { throw MankaiErrorCode.pluginMangaNotFound.makeError() }

        switch book.mediaType { case .pse:
            guard let url = URL(string: image) else { throw URLError(.badURL) }
            return try await session.download(url: url)
            case .regular(let url, let type):
                guard let regularFile = regularFileInfo(url: url, type: type) else {
                    throw MankaiErrorCode.browseFilesystemParserNotFound.makeError()
                }
                let fileName = regularFile.fileName
                let parser = regularFile.parser
                let file = OpdsParserFile(
                    cacheKey: book.id, remoteURL: url, fileName: fileName, session: session,
                    temporaryDirectory: temporaryDirectory)
                return try await parser.parseImage(url: image, file: file)
        }
    }

    private func regularFileInfo(url: URL, type: String?) -> RegularFileInfo? {
        let fileName = url.lastPathComponent
        if let type = type?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty,
            let mimeType = type.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            let parser = mimeTypes[mimeType]
        {
            return RegularFileInfo(fileName: fileName, parser: parser)
        }

        guard let parser = parsers[(fileName as NSString).pathExtension.lowercased()] else {
            return nil
        }
        return RegularFileInfo(fileName: fileName, parser: parser)
    }

    private func store(books: [OpdsBookEntry]) async throws {
        guard !books.isEmpty else { return }
        guard let db = DbService.shared.openOpdsBrowsablePluginDb() else {
            throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
        }

        let encoder = JSONEncoder()
        let models = try books.map { book -> OpdsBrowsableBookModel in
            let data = try encoder.encode(book)
            guard let info = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return OpdsBrowsableBookModel(pluginId: id, bookId: book.id, info: info)
        }

        try await db.write { db in for model in models { try model.upsert(db) } }
    }

    private func cachedBooks(for ids: [String]) async throws -> [OpdsBookEntry] {
        guard !ids.isEmpty else { return [] }
        guard let db = DbService.shared.openOpdsBrowsablePluginDb() else {
            throw MankaiErrorCode.browseFilesystemDatabaseNotAvailable.makeError()
        }
        let pluginId = id

        let models = try await db.read { db in
            try OpdsBrowsableBookModel.filter(
                Column("pluginId") == pluginId && ids.contains(Column("bookId"))
            )
            .fetchAll(db)
        }
        let booksById: [String: OpdsBookEntry] = Dictionary(
            uniqueKeysWithValues: models.compactMap { model -> (String, OpdsBookEntry)? in
                guard let data = model.info.data(using: .utf8),
                    let book = try? JSONDecoder().decode(OpdsBookEntry.self, from: data)
                else { return nil }
                return (model.bookId, book)
            })

        return ids.compactMap { booksById[$0] }
    }

    private func cachedBook(for id: String) async throws -> OpdsBookEntry? {
        try await cachedBooks(for: [id]).first
    }

    private func detailedManga(for id: String) async throws -> DetailedManga {
        guard let book = try await cachedBook(for: id) else {
            Logger.opdsBrowsablePlugin.warning("OPDS book not found in database: \(id)")
            throw MankaiErrorCode.pluginMangaNotFound.makeError()
        }
        return detailedManga(from: book)
    }

    private func detailedManga(from book: OpdsBookEntry) -> DetailedManga {
        var manga = DetailedManga()
        manga.id = book.id
        manga.title = book.title
        manga.cover = book.coverURL?.absoluteString
        manga.description = book.description
        manga.authors = book.authors
        manga.genres = BrowsableMangaUtilities.genres(from: book.genres)

        let chapter = Chapter(id: "0", title: book.title)
        manga.chapters = [ChapterGroup(title: "volume", chapters: [chapter])]
        manga.latestChapter = chapter
        return manga
    }

}
