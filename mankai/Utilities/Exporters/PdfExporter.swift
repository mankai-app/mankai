//
//  PdfExporter.swift
//  mankai
//
//  Created by Travis XU on 4/10/2026.
//

import CoreGraphics
import Foundation
import ImageIO

struct PdfExporter: Sendable {
    static let shared = PdfExporter()

    private init() {}

    private struct Content: Sendable {
        let chapter: Chapter
        let pages: [String]
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

        let exportRoot = Exporter.temporaryDirectory.appendingPathComponent(
            "pdf", isDirectory: true)
        let directory = exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let title = manga.title ?? manga.id
        let authors = manga.authors.joined(separator: ", ")

        Logger.pdfExporter.info("Exporting \(content.count) chapters as separate PDFs")
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)

            let totalPages = content.reduce(0) { $0 + $1.pages.count }
            var completedPages = 0
            var urls: [URL] = []
            for (index, item) in content.enumerated() {
                try Task.checkCancellation()
                let chapterTitle = item.chapter.title ?? item.chapter.id
                // A leading sequence keeps filenames unique even after sanitizing or truncating.
                let filename = FileUtilities.filename(
                    for: "\(String(format: "%03d", index + 1)) - \(title) - \(chapterTitle)",
                    fileExtension: "pdf")
                let url = directory.appendingPathComponent(filename)
                let previousPages = completedPages
                try await self.writeChapter(
                    item, to: url, title: "\(title) - \(chapterTitle)", authors: authors
                ) { pageCount in
                    await progress(Double(previousPages + pageCount) / Double(totalPages))
                }
                try Task.checkCancellation()
                guard let document = CGPDFDocument(url as CFURL),
                    document.numberOfPages == item.pages.count
                else { throw MankaiErrorCode.exportFailedToCreatePdf.makeError() }
                urls.append(url)
                completedPages += item.pages.count
            }
            try Task.checkCancellation()
            return urls
        }

        do {
            let urls = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            Logger.pdfExporter.info("Export completed: \(urls.count) PDF files")
            return urls
        } catch {
            try? FileUtilities.clearDirectoryIfPresent(at: directory)
            throw error
        }
    }

    /// Writes one page at a time to disk instead of retaining a chapter's decoded images.
    private func writeChapter(
        _ content: Content, to url: URL, title: String, authors: String,
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws {
        let metadata: [String: Any] = [
            kCGPDFContextTitle as String: title, kCGPDFContextAuthor as String: authors,
            kCGPDFContextCreator as String: "Mankai"
        ]
        guard let consumer = CGDataConsumer(url: url as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: nil, metadata as CFDictionary)
        else { throw MankaiErrorCode.exportFailedToCreatePdf.makeError() }
        defer { context.closePDF() }

        for (index, path) in content.pages.enumerated() {
            try Task.checkCancellation()
            let data = try await DownloadPlugin.shared.getImage(path)
            try Task.checkCancellation()
            try autoreleasepool { try Self.writePage(data, to: context) }
            try Task.checkCancellation()
            await progress(index + 1)
        }
    }

    private static func writePage(_ data: Data, to context: CGContext) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int, width > 0,
            height > 0
        else { throw MankaiErrorCode.pluginDownloadFailedToLoadImage.makeError() }

        // Apply EXIF rotation/mirroring while retaining the full source resolution.
        let options: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: max(width, height),
            kCGImageSourceShouldCacheImmediately as String: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw MankaiErrorCode.pluginDownloadFailedToLoadImage.makeError() }
        try Task.checkCancellation()

        // Keep long pages within PDF's standard size limit without changing their proportions.
        let scale = min(1, 14_400 / CGFloat(max(image.width, image.height)))
        var bounds = CGRect(
            x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let mediaBox = withUnsafeBytes(of: &bounds) { Data($0) }
        context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        context.endPDFPage()
    }

    @MainActor private func loadContent(
        manga: DetailedManga, downloadMangaId: String, chapters: ChapterGroups
    ) async throws -> [Content] {
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

        var content: [Content] = []
        for chapter in selectedChapters {
            try Task.checkCancellation()
            let paths = try await plugin.getChapter(manga: downloadedManga, chapter: chapter)
            try Task.checkCancellation()
            guard !paths.isEmpty else {
                throw MankaiErrorCode.exportChaptersNotDownloaded.makeError()
            }
            content.append(Content(chapter: chapter, pages: paths))
        }
        return content
    }

}
