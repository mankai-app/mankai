//
//  MmaExporter.swift
//  mankai
//
//  Created by Travis XU on 3/10/2026.
//

import Foundation
import ZIPFoundation

struct MmaExporter: Sendable {
    static let shared = MmaExporter()

    private let id = "mma"

    private init() {}

    private struct Content: Sendable {
        let manga: DetailedManga
        let pages: [String: [String]]
        let cover: String?
    }

    @MainActor func export(
        manga: DetailedManga, downloadMangaId: String, chapters: ChapterGroups,
        progress: @escaping ExportProgressHandler
    ) async throws -> [URL] {
        try Task.checkCancellation()
        await progress(0)
        let content = try await loadContent(
            manga: manga, downloadMangaId: downloadMangaId, chapters: chapters)
        try Task.checkCancellation()

        let exportRoot = Exporter.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        let directory = exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(
            FileUtilities.filename(for: manga.title ?? manga.id, fileExtension: id))

        Logger.mmaExporter.info("Exporting \(chapters.flatMap(\.chapters).count) chapters as MMA")
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try await self.writeArchive(content, to: url, progress: progress)
            try Task.checkCancellation()
        }

        do {
            try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            Logger.mmaExporter.info("Export completed: \(url.lastPathComponent)")
            return [url]
        } catch {
            try? FileUtilities.clearDirectoryIfPresent(at: directory)
            throw error
        }
    }

    private func writeArchive(
        _ content: Content, to url: URL, progress: @escaping ExportProgressHandler
    ) async throws {
        try Task.checkCancellation()
        let archive = try Archive(url: url, accessMode: .create)
        let totalFiles =
            content.pages.values.reduce(0) { $0 + $1.count } + (content.cover == nil ? 0 : 1) + 1
        var completedFiles = 0

        let encodedManga = try JSONEncoder().encode(content.manga)
        guard var metadata = try JSONSerialization.jsonObject(with: encodedManga) as? [String: Any]
        else { throw MankaiErrorCode.exportInvalidSelection.makeError() }

        // Plugin metadata and edit permissions belong to the source, not to the portable archive.
        metadata.removeValue(forKey: "meta")
        metadata.removeValue(forKey: "editable")
        metadata.removeValue(forKey: "cover")

        if let cover = content.cover {
            let data: Data?
            do { data = try await loadImage(cover) } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                Logger.mmaExporter.warning("Failed to load downloaded cover: \(error)")
                data = nil
            }
            if let data {
                let path = "cover.\(imageExtension(for: cover))"
                try addData(data, path: path, to: archive)
                metadata["cover"] = path
            }
            completedFiles += 1
            await progress(Double(completedFiles) / Double(totalFiles))
        }

        var groups: [[String: Any]] = []
        var firstPagePath: String?
        for (groupIndex, group) in content.manga.chapters.enumerated() {
            var chapters: [[String: Any]] = []
            for (chapterIndex, chapter) in group.chapters.enumerated() {
                guard let pages = content.pages[chapter.id], !pages.isEmpty else {
                    throw MankaiErrorCode.exportChaptersNotDownloaded.makeError()
                }

                var imagePaths: [String] = []
                for (pageIndex, page) in pages.enumerated() {
                    try Task.checkCancellation()
                    // Numeric paths keep source IDs and URLs out of archive filenames.
                    let path =
                        "images/\(groupIndex + 1)/\(chapterIndex + 1)/\(pageIndex + 1).\(imageExtension(for: page))"
                    let data = try await loadImage(page)
                    try addData(data, path: path, to: archive)
                    imagePaths.append(path)
                    if firstPagePath == nil { firstPagePath = path }
                    completedFiles += 1
                    await progress(Double(completedFiles) / Double(totalFiles))
                }

                var chapterMetadata: [String: Any] = ["id": chapter.id, "images": imagePaths]
                if let title = chapter.title { chapterMetadata["title"] = title }
                chapters.append(chapterMetadata)
            }

            var groupMetadata: [String: Any] = ["title": group.title, "chapters": chapters]
            if let id = group.id { groupMetadata["id"] = id }
            groups.append(groupMetadata)
        }

        metadata["chapters"] = groups
        if metadata["cover"] == nil { metadata["cover"] = firstPagePath }
        let data = try JSONSerialization.data(
            withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try Task.checkCancellation()
        try addData(data, path: "metadata.json", to: archive, compressionMethod: .deflate)
        try Task.checkCancellation()
        await progress(1)
    }

    /// Loads only the current page through the download plugin.
    private func loadImage(_ path: String) async throws -> Data {
        try Task.checkCancellation()
        let data = try await DownloadPlugin.shared.getImage(path)
        try Task.checkCancellation()
        guard !data.isEmpty else {
            throw MankaiErrorCode.pluginDownloadFailedToLoadImage.makeError()
        }
        return data
    }

    private func addData(
        _ data: Data, path: String, to archive: Archive,
        compressionMethod: CompressionMethod = .none
    ) throws {
        try Task.checkCancellation()
        try archive.addEntry(
            with: path, type: .file, uncompressedSize: Int64(data.count),
            compressionMethod: compressionMethod
        ) { position, size in
            try Task.checkCancellation()
            let start = Int(position)
            return data.subdata(in: start..<min(start + size, data.count))
        }
    }

    private func imageExtension(for path: String) -> String {
        let ext = URL(string: path)?.pathExtension.lowercased() ?? ""
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        return !ext.isEmpty && ext.unicodeScalars.allSatisfy(allowedCharacters.contains)
            ? ext : "img"
    }

    /// Refreshes download availability through the plugin before preparing the archive.
    @MainActor private func loadContent(
        manga: DetailedManga, downloadMangaId: String, chapters: ChapterGroups
    ) async throws -> Content {
        let selectedChapters = chapters.flatMap(\.chapters)
        guard !selectedChapters.isEmpty else {
            throw MankaiErrorCode.exportNoChaptersSelected.makeError()
        }
        let selectedIds = Set(selectedChapters.map(\.id))
        guard selectedIds.count == selectedChapters.count, !selectedIds.contains("") else {
            throw MankaiErrorCode.exportInvalidSelection.makeError()
        }

        let plugin = DownloadPlugin.shared
        let downloadedManga = try await plugin.getDetailedManga(downloadMangaId)
        try Task.checkCancellation()
        guard downloadedManga.id == manga.id else {
            throw MankaiErrorCode.pluginDownloadMangaNotFound.makeError()
        }
        let downloadedChapterIds = Set(
            downloadedManga.chapters.flatMap(\.chapters).filter { $0.locked != true }.map(\.id))
        guard selectedIds.isSubset(of: downloadedChapterIds) else {
            throw MankaiErrorCode.exportChaptersNotDownloaded.makeError()
        }

        var pages: [String: [String]] = [:]
        for chapter in selectedChapters {
            try Task.checkCancellation()
            let paths = try await plugin.getChapter(manga: downloadedManga, chapter: chapter)
            try Task.checkCancellation()
            guard !paths.isEmpty else {
                throw MankaiErrorCode.exportChaptersNotDownloaded.makeError()
            }
            pages[chapter.id] = paths
        }

        var exportManga = manga
        exportManga.chapters = chapters.filter { !$0.chapters.isEmpty }
            .map { group in
                var group = group
                group.chapters = group.chapters.map { chapter in
                    var chapter = chapter
                    chapter.locked = nil
                    return chapter
                }
                return group
            }
        let exportedChapters = exportManga.chapters.flatMap(\.chapters)
        exportManga.latestChapter =
            exportedChapters.first(where: { $0.id == manga.latestChapter?.id })
            ?? exportedChapters.last
        exportManga.cover = nil
        exportManga.meta = nil
        exportManga.editable = nil

        return Content(manga: exportManga, pages: pages, cover: downloadedManga.cover)
    }

}
