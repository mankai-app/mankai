//
//  MmaParser.swift
//  mankai
//
//  Created by Travis XU on 2/10/2026.
//

import Foundation

/// A ZIP containing root-level metadata.json with DetailedManga fields and an ordered `images` array on each chapter.
/// Cover and page paths are relative to the ZIP root.
final class MmaParser: Parser {
    private let archiveReader = ZipArchiveReader(logger: .mmaParser)

    private struct Metadata: Decodable {
        struct Group: Decodable {
            struct ChapterImages: Decodable {
                let id: String
                let images: [String]
            }

            let chapters: [ChapterImages]
        }

        let manga: DetailedManga
        let groups: [Group]

        private enum CodingKeys: String, CodingKey { case chapters }

        init(from decoder: Decoder) throws {
            manga = try DetailedManga(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            groups = try container.decode([Group].self, forKey: .chapters)
        }
    }

    override var id: String { "mma" }

    override var supportedExtensions: [String] { ["mma"] }

    override var supportedMimeTypes: [String] { ["application/vnd.mankai.mma+zip"] }

    override func parse(file: ParserFile) async throws -> DetailedManga {
        Logger.mmaParser.debug("Parsing archive: \(file.fileName)")
        let data = try await archiveReader.readEntry(path: "metadata.json", file: file)
        let metadata: Metadata
        do { metadata = try JSONDecoder().decode(Metadata.self, from: data) } catch {
            throw MankaiErrorCode.browseArchiveInvalidMetadata.makeError(underlyingError: error)
        }

        var pages: [String: [String]] = [:]
        for chapter in metadata.groups.flatMap(\.chapters) {
            guard !chapter.id.isEmpty, pages[chapter.id] == nil else {
                throw MankaiErrorCode.browseArchiveInvalidMetadata.makeError()
            }
            guard !chapter.images.isEmpty else {
                throw MankaiErrorCode.browseArchiveNoImagesFoundInArchive.makeError()
            }
            for path in chapter.images { try validateImagePath(path) }
            pages[chapter.id] = chapter.images
        }
        guard !pages.isEmpty else {
            throw MankaiErrorCode.browseArchiveNoImagesFoundInArchive.makeError()
        }

        var manga = metadata.manga
        if let cover = manga.cover { try validateImagePath(cover) }
        if let latestChapter = manga.latestChapter {
            guard pages[latestChapter.id] != nil else {
                throw MankaiErrorCode.browseArchiveInvalidMetadata.makeError()
            }
        } else {
            manga.latestChapter = manga.chapters.flatMap(\.chapters).last
        }
        manga.meta = try ParserChapterMetadata(chapters: pages).encoded()
        return manga
    }

    override func parseChapter(manga: DetailedManga, chapter: Chapter, file: ParserFile)
        async throws -> [String]
    {
        if let pages = ParserChapterMetadata.decode(manga.meta)?.pages(for: chapter.id) {
            return pages
        }

        let parsed = try await parse(file: file)
        guard let pages = ParserChapterMetadata.decode(parsed.meta)?.pages(for: chapter.id) else {
            throw MankaiErrorCode.browseArchiveEntryNotFound.makeError()
        }
        return pages
    }

    override func parseImage(url: String, file: ParserFile) async throws -> Data {
        try validateImagePath(url)
        return try await archiveReader.readEntry(path: url, file: file)
    }

    private func validateImagePath(_ path: String) throws {
        guard PathUtilities.isValidRelativePath(path) else {
            Logger.mmaParser.error("Invalid archive-relative image path: \(path)")
            throw MankaiErrorCode.browseArchiveInvalidMetadata.makeError()
        }
    }
}
