//
//  BrowsableUtilities.swift
//  mankai
//
//  Created by Travis XU on 10/8/2026.
//

import Foundation
import SwiftUI

/// Coordinates parser downloads that target the same local cache file.
final class ParserFileDownloadRegistry: @unchecked Sendable {
    static let shared = ParserFileDownloadRegistry()

    private let downloads = AsyncLoadRegistry<URL>()

    func file(at localURL: URL, download: @escaping @Sendable (URL) async throws -> Void)
        async throws -> URL
    {
        let key = localURL.path(percentEncoded: false)
        return try await downloads.value(for: key) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: key) {
                Logger.browseService.debug("Parser cache hit: \(key)")
                return localURL
            }

            try fileManager.createDirectory(
                at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            do {
                try await download(localURL)
                try Task.checkCancellation()
                return localURL
            } catch {
                try? fileManager.removeItem(at: localURL)
                throw error
            }
        }
    }
}

enum BrowsablePluginUtilities {
    private static let prefix = "data:application/json;base64,"

    static func encode<Model: Encodable>(_ model: Model) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Folder models contain only strings, integers, and booleans.
        let data = try! encoder.encode(model)
        return prefix + data.base64EncodedString()
    }

    static func decode<Model: Decodable>(_ url: String) -> Model? {
        guard url.hasPrefix(prefix),
            let data = Data(base64Encoded: String(url.dropFirst(prefix.count)))
        else { return nil }
        return try? JSONDecoder().decode(Model.self, from: data)
    }

    static func resolveIdentity<Session: BrowsableSession>(
        using session: Session, invalidPluginError: @autoclosure () -> Error
    ) async throws -> (id: String, shouldSync: Bool) {
        if let data = try await session.fileIfExists(path: ".mankai") {
            guard let value = String(data: data, encoding: .utf8) else {
                throw invalidPluginError()
            }

            let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw invalidPluginError() }
            return (id: id, shouldSync: true)
        }

        let id = UUID().uuidString
        do {
            try await session.upload(data: Data(id.utf8), path: ".mankai")
            return (id: id, shouldSync: true)
        } catch {
            Session.logger.warning(
                "Failed to write .mankai for plugin \(id), using a local-only ID: \(error)")
            return (id: id, shouldSync: false)
        }
    }
}

enum BrowsableMangaUtilities {
    static func genres(from values: [String]) -> [Genre] {
        var seen = Set<Genre>()
        var result: [Genre] = []

        for value in values {
            let normalizedValue = normalizedGenreName(value)
            guard
                let genre = Genre.allCases.first(where: {
                    $0 != .all && normalizedGenreName($0.rawValue) == normalizedValue
                }), seen.insert(genre).inserted
            else { continue }
            result.append(genre)
        }
        return result
    }

    private static func normalizedGenreName(_ value: String) -> String {
        value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            .map(String.init).joined()
    }
}

struct LabeledFolderIcon: View {
    let label: String
    let color: Color

    var body: some View {
        Image(systemName: "folder.fill")
            .overlay {
                Text(label).font(.system(size: 6, weight: .bold, design: .rounded))
                    .foregroundStyle(color).offset(y: 2)
            }
    }
}

enum BrowsablePluginStyle {
    static let palette: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown
    ]

    static func color(for id: String) -> Color {
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = (hash &<< 5) &+ hash &+ UInt64(byte) }
        let index = Int(hash % UInt64(palette.count))
        return palette[index]
    }
}
