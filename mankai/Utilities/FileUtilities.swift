//
//  FileUtilities.swift
//  mankai
//
//  Created by Travis XU on 4/10/2026.
//

import CryptoKit
import Foundation

/// Shared filename, cache, hashing, and file cleanup operations.
enum FileUtilities {
    /// Returns a safe filename stem limited to 200 UTF-8 bytes.
    nonisolated static func sanitizedStem(_ title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        var name = title.components(separatedBy: invalidCharacters).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > 200 { name.removeLast() }
        if name.isEmpty || name == "." || name == ".." { name = "Export" }
        return name
    }

    /// Adds a trusted file extension to a sanitized filename stem.
    nonisolated static func filename(for title: String, fileExtension: String) -> String {
        "\(sanitizedStem(title)).\(fileExtension)"
    }

    static func cacheURL(for key: String, in directory: URL) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let extensionName = (key as NSString).pathExtension
        let fileName = extensionName.isEmpty ? hash : "\(hash).\(extensionName)"
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    static func sha256(of fileURL: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                let chunk = handle.readData(ofLength: 1 << 16)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        .value
    }

    static func uniqueFileName(for source: URL, existingNames: Set<String>) -> String {
        let baseName = source.lastPathComponent.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let stem = (baseName as NSString).deletingPathExtension
        let extensionName = (baseName as NSString).pathExtension

        func candidate(_ suffix: String) -> String {
            let name = suffix.isEmpty ? stem : "\(stem) \(suffix)"
            return extensionName.isEmpty ? name : "\(name).\(extensionName)"
        }

        var result = candidate("")
        var counter = 1
        while existingNames.contains(result) {
            result = candidate("(\(counter))")
            counter += 1
        }
        return result
    }

    static func clearDirectoryIfPresent(at directory: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path(percentEncoded: false)) {
            try fileManager.removeItem(at: directory)
        }
    }
}
