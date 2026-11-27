//
//  CbrThumbnailHandler.swift
//  mankaiThumbnail
//
//  Created by Travis XU on 1/8/2026.
//

import UIKit
import Unrar

/// Extracts the cover image of a CBR comic archive.
final class CbrThumbnailHandler: ThumbnailHandler {
    let supportedExtensions: Set<String> = ["cbr"]

    /// Image extensions supported as cover candidates inside a CBR archive.
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "webp", "tiff", "tif"
    ]

    func coverImage(from url: URL) throws -> UIImage? {
        let archive = try Unrar.Archive(fileURL: url)
        var seenFilenames = Set<String>()
        let entries = try archive.entries().filter { seenFilenames.insert($0.fileName).inserted }

        let imageEntries = entries.filter { Self.isImagePath($0.fileName) }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }

        guard let firstImage = imageEntries.first else { return nil }

        let coverEntry =
            Self.comicInfoEntry(in: entries)
            .flatMap { infoEntry in try? archive.extract(infoEntry) }
            .flatMap { data in ComicInfoCoverParser.frontCoverIndex(from: data) }
            .flatMap { index in imageEntries.indices.contains(index) ? imageEntries[index] : nil }
            ?? firstImage

        let data = try archive.extract(coverEntry)
        return UIImage(data: data)
    }

    // MARK: - Helpers

    private static func comicInfoEntry(in entries: [Unrar.Entry]) -> Unrar.Entry? {
        if let rootEntry = entries.first(where: { $0.fileName == "ComicInfo.xml" }) {
            return rootEntry
        }

        return entries.first { entry in
            let normalizedPath = entry.fileName.replacingOccurrences(of: "\\", with: "/")
            let name = (normalizedPath as NSString).lastPathComponent
            return !normalizedPath.contains("__MACOSX/")
                && name.caseInsensitiveCompare("ComicInfo.xml") == .orderedSame
        }
    }

    private static func isImagePath(_ path: String) -> Bool {
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        let name = (normalizedPath as NSString).lastPathComponent

        // Ignore hidden files and macOS metadata folders.
        if name.hasPrefix(".") || normalizedPath.contains("__MACOSX/") { return false }

        let ext = (name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }
}
