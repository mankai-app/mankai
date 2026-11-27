//
//  CbrParser.swift
//  mankai
//
//  Created by Travis XU on 2/8/2026.
//

import Foundation
import Unrar

final class CbrParser: Parser {
    /// Stores each archive's entries and the lock that serializes reads.
    nonisolated private final class CachedArchive: @unchecked Sendable {
        let archive: Unrar.Archive
        let filenames: [String]
        let entriesByFilename: [String: Unrar.Entry]
        let readLock = NSLock()

        init(archive: Unrar.Archive, entries: [Unrar.Entry]) {
            var filenames: [String] = []
            var entriesByFilename: [String: Unrar.Entry] = [:]
            for entry in entries where entriesByFilename[entry.fileName] == nil {
                filenames.append(entry.fileName)
                entriesByFilename[entry.fileName] = entry
            }

            self.archive = archive
            self.filenames = filenames
            self.entriesByFilename = entriesByFilename
        }
    }

    private var cachedArchiveKey: String?
    private var cachedArchive: CachedArchive?
    private let cacheLock = NSLock()
    private let archiveLoadRegistry = AsyncLoadRegistry<CachedArchive>()

    private func cachedArchive(for cacheKey: String) -> CachedArchive? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard cachedArchiveKey == cacheKey else { return nil }
        return cachedArchive
    }

    private func storeArchive(_ archive: CachedArchive, for cacheKey: String) -> CachedArchive {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if cachedArchiveKey == cacheKey, let cachedArchive { return cachedArchive }

        cachedArchiveKey = cacheKey
        cachedArchive = archive
        return archive
    }

    private func archive(for file: ParserFile) async throws -> CachedArchive {
        if let cached = cachedArchive(for: file.cacheKey) {
            Logger.cbrParser.debug("Reusing cached archive: \(file.cacheKey)")
            return cached
        }

        return try await archiveLoadRegistry.value(for: file.cacheKey) { @MainActor [self, file] in
            if let cached = cachedArchive(for: file.cacheKey) {
                Logger.cbrParser.debug("Reusing cached archive: \(file.cacheKey)")
                return cached
            }

            Logger.cbrParser.debug("Loading archive: \(file.cacheKey)")
            let url = try await file.getUrl()
            let loadedArchive =
                try await Task.detached(priority: .utility) {
                    let archive = try Unrar.Archive(fileURL: url)
                    let entries = try archive.entries()
                    return CachedArchive(archive: archive, entries: entries)
                }
                .value
            return storeArchive(loadedArchive, for: file.cacheKey)
        }
    }

    nonisolated private static func performRead<T>(
        cachedArchive: CachedArchive, body: @Sendable (CachedArchive) throws -> T
    ) rethrows -> T {
        cachedArchive.readLock.lock()
        defer { cachedArchive.readLock.unlock() }
        return try body(cachedArchive)
    }

    private func withReadLock<T: Sendable>(
        for file: ParserFile, body: @escaping @Sendable (CachedArchive) throws -> T
    ) async throws -> T {
        Logger.cbrParser.debug("Acquiring read lock for: \(file.cacheKey)")
        let cachedArchive = try await archive(for: file)
        return
            try await Task.detached(priority: .utility) {
                try Self.performRead(cachedArchive: cachedArchive, body: body)
            }
            .value
    }

    override var id: String { "cbr" }

    override var supportedExtensions: [String] { ["cbr"] }

    override var supportedMimeTypes: [String] {
        ["application/vnd.comicbook-rar", "application/x-cbr", "application/x-rar-compressed"]
    }

    override func parse(file: ParserFile) async throws -> DetailedManga {
        Logger.cbrParser.debug("Parsing archive: \(file.fileName)")

        let fileName = file.fileName
        let parsed: (imagePaths: [String], info: ComicInfo?, coverPath: String?) =
            try await withReadLock(for: file) { cachedArchive in
                let archive = cachedArchive.archive
                let imagePaths = Self.sortedImagePaths(in: cachedArchive.filenames)

                guard !imagePaths.isEmpty else {
                    Logger.cbrParser.error("No supported images found in archive: \(fileName)")
                    throw MankaiErrorCode.browseArchiveNoImagesFoundInArchive.makeError()
                }

                let info: ComicInfo?
                if let infoEntry = cachedArchive.entriesByFilename["ComicInfo.xml"],
                    let infoData = try? archive.extract(infoEntry)
                {
                    Logger.cbrParser.debug("Found ComicInfo.xml, parsing metadata")
                    info = ComicInfoParser.parse(data: infoData)
                    if info == nil {
                        Logger.cbrParser.warning(
                            "ComicInfo.xml exists but could not be parsed, proceeding with image-only mode"
                        )
                    }
                } else {
                    info = nil
                    Logger.cbrParser.debug(
                        "No ComicInfo.xml found, deferring filename metadata to presentation")
                }

                let coverPath =
                    info?.frontCoverIndex
                    .flatMap { index in
                        guard index >= 0, index < imagePaths.count else { return nil }
                        return imagePaths[index]
                    } ?? imagePaths.first

                return (imagePaths, info, coverPath)
            }

        var manga = ComicArchiveSupport.detailedManga(
            info: parsed.info, coverPath: parsed.coverPath)
        if let chapter = manga.latestChapter {
            manga.meta = try ParserChapterMetadata(chapterId: chapter.id, pages: parsed.imagePaths)
                .encoded()
        }

        Logger.cbrParser.debug("Parsed \(parsed.imagePaths.count) images")
        return manga
    }

    override func prepareForPresentation(_ manga: DetailedManga, file: ParserFile) -> DetailedManga
    { ComicArchiveSupport.prepareForPresentation(manga, file: file) }

    override func parseChapter(manga: DetailedManga, chapter: Chapter, file: ParserFile)
        async throws -> [String]
    {
        Logger.cbrParser.debug("Parsing chapter images for manga: \(manga.id)")

        if let pages = ParserChapterMetadata.decode(manga.meta)?.pages(for: chapter.id) {
            Logger.cbrParser.debug(
                "Using \(pages.count) cached page references for chapter: \(chapter.id)")
            return pages
        }

        Logger.cbrParser.debug("No compatible chapter metadata found, reparsing archive")

        let imagePaths = try await withReadLock(for: file) { cachedArchive in
            Self.sortedImagePaths(in: cachedArchive.filenames)
        }

        Logger.cbrParser.debug("Found \(imagePaths.count) images for chapter of \(manga.id)")
        return imagePaths
    }

    override func parseImage(url: String, file: ParserFile) async throws -> Data {
        Logger.cbrParser.debug("Reading image: \(url)")

        return try await withReadLock(for: file) { cachedArchive in
            guard let entry = cachedArchive.entriesByFilename[url] else {
                Logger.cbrParser.error("Entry not found in archive: \(url)")
                throw MankaiErrorCode.browseArchiveEntryNotFound.makeError()
            }
            return try cachedArchive.archive.extract(entry)
        }
    }

    nonisolated private static func sortedImagePaths(in filenames: [String]) -> [String] {
        filenames.filter(ComicArchiveSupport.isImagePath)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
