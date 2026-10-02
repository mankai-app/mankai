//
//  MmaThumbnailHandler.swift
//  mankaiThumbnail
//
//  Created by Travis XU on 2/10/2026.
//

import UIKit
import ZIPFoundation

/// Extracts the cover referenced by an MMA archive's root metadata.json.
final class MmaThumbnailHandler: ThumbnailHandler {
    let supportedExtensions: Set<String> = ["mma"]

    private struct Metadata: Decodable { let cover: String? }

    func coverImage(from url: URL) throws -> UIImage? {
        let archive = try Archive(url: url, accessMode: .read)
        guard let metadataEntry = archive["metadata.json"], metadataEntry.type == .file else {
            return nil
        }

        let metadataData = try Self.entryData(archive: archive, entry: metadataEntry)
        let metadata = try JSONDecoder().decode(Metadata.self, from: metadataData)
        guard let coverPath = metadata.cover, Self.isValidRelativePath(coverPath),
            let coverEntry = archive[coverPath], coverEntry.type == .file
        else { return nil }

        let imageData = try Self.entryData(archive: archive, entry: coverEntry)
        return UIImage(data: imageData)
    }

    private static func isValidRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.contains("\\") && components.first?.contains(":") == false
            && components.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
            }
    }

    private static func entryData(archive: Archive, entry: Entry) throws -> Data {
        var data = Data()
        _ = try archive.extract(entry, consumer: { chunk in data.append(chunk) })
        return data
    }
}
