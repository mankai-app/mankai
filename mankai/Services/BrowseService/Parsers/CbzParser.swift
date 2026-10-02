//
//  CbzParser.swift
//  mankai
//
//  Created by Travis XU on 14/7/2026.
//

import Foundation
import ZIPFoundation

final class CbzParser: Parser {
    private let archiveReader = ZipArchiveReader(logger: .cbzParser)

    override var id: String { "cbz" }

    override var supportedExtensions: [String] { ["cbz"] }

    override var supportedMimeTypes: [String] {
        ["application/vnd.comicbook+zip", "application/x-cbz"]
    }

    override func parse(file: ParserFile) async throws -> DetailedManga {
        Logger.cbzParser.debug("Parsing archive: \(file.fileName)")

        let fileName = file.fileName
        let parsed: (imagePaths: [String], info: ComicInfo?, coverPath: String?) =
            try await archiveReader.withReadLock(for: file) { archive in
                let imageEntries =
                    archive.compactMap { entry -> Entry? in
                        guard entry.type == .file, ComicArchiveSupport.isImagePath(entry.path)
                        else { return nil }
                        return entry
                    }
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

                guard !imageEntries.isEmpty else {
                    Logger.cbzParser.error("No supported images found in archive: \(fileName)")
                    throw MankaiErrorCode.browseArchiveNoImagesFoundInArchive.makeError()
                }

                let info: ComicInfo?
                if let infoEntry = archive["ComicInfo.xml"],
                    let infoData = try? ZipArchiveReader.entryData(
                        archive: archive, entry: infoEntry)
                {
                    Logger.cbzParser.debug("Found ComicInfo.xml, parsing metadata")
                    info = ComicInfoParser.parse(data: infoData)
                    if info == nil {
                        Logger.cbzParser.warning(
                            "ComicInfo.xml exists but could not be parsed, proceeding with image-only mode"
                        )
                    }
                } else {
                    info = nil
                    Logger.cbzParser.debug(
                        "No ComicInfo.xml found, deferring filename metadata to presentation")
                }

                let coverEntry =
                    info?.frontCoverIndex
                    .flatMap { idx -> Entry? in
                        guard idx >= 0, idx < imageEntries.count else { return nil }
                        return imageEntries[idx]
                    } ?? imageEntries.first

                return (imageEntries.map(\.path), info, coverEntry?.path)
            }

        var manga = ComicArchiveSupport.detailedManga(
            info: parsed.info, coverPath: parsed.coverPath)
        if let chapter = manga.latestChapter {
            manga.meta = try ParserChapterMetadata(chapterId: chapter.id, pages: parsed.imagePaths)
                .encoded()
        }

        Logger.cbzParser.debug("Parsed \(parsed.imagePaths.count) images")
        return manga
    }

    override func prepareForPresentation(_ manga: DetailedManga, file: ParserFile) -> DetailedManga
    { ComicArchiveSupport.prepareForPresentation(manga, file: file) }

    override func parseChapter(manga: DetailedManga, chapter: Chapter, file: ParserFile)
        async throws -> [String]
    {
        Logger.cbzParser.debug("Parsing chapter images for manga: \(manga.id)")

        if let pages = ParserChapterMetadata.decode(manga.meta)?.pages(for: chapter.id) {
            Logger.cbzParser.debug(
                "Using \(pages.count) cached page references for chapter: \(chapter.id)")
            return pages
        }

        Logger.cbzParser.debug("No compatible chapter metadata found, reparsing archive")

        let imagePaths = try await archiveReader.withReadLock(for: file) { archive in
            archive.compactMap { entry -> String? in
                guard entry.type == .file, ComicArchiveSupport.isImagePath(entry.path) else {
                    return nil
                }
                return entry.path
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        Logger.cbzParser.debug("Found \(imagePaths.count) images for chapter of \(manga.id)")
        return imagePaths
    }

    override func parseImage(url: String, file: ParserFile) async throws -> Data {
        try await archiveReader.readEntry(path: url, file: file)
    }

}
