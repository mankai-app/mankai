//
//  Exporter.swift
//  mankai
//
//  Created by Travis XU on 3/10/2026.
//

import Foundation

typealias ExportProgressHandler = @Sendable (Double) async -> Void

enum Exporter: String, CaseIterable, Identifiable, Sendable {
    case mma
    case pdf

    var id: String { rawValue }

    var name: String {
        switch self { case .mma: return "MMA" case .pdf: return "PDF"
        }
    }

    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
    }

    static func clearTemporaryFiles() {
        do { try FileUtilities.clearDirectoryIfPresent(at: temporaryDirectory) } catch {
            Logger.general.error("Failed to clear temporary export files", error: error)
        }
    }

    /// Returns all completed files produced by the selected exporter.
    func export(
        manga: DetailedManga, downloadMangaId: String, chapters: ChapterGroups,
        progress: @escaping ExportProgressHandler
    ) async throws -> [URL] {
        switch self { case .mma:
            return try await MmaExporter.shared.export(
                manga: manga, downloadMangaId: downloadMangaId, chapters: chapters,
                progress: progress)
            case .pdf:
                return try await PdfExporter.shared.export(
                    manga: manga, downloadMangaId: downloadMangaId, chapters: chapters,
                    progress: progress)
        }
    }
}
