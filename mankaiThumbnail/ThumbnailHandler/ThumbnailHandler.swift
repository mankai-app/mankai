//
//  ThumbnailHandler.swift
//  mankaiThumbnail
//
//  Created by Travis XU on 16/7/2026.
//

import UIKit

protocol ThumbnailHandler: Sendable {
    /// Lowercased file extensions (without a leading dot) this handler supports.
    var supportedExtensions: Set<String> { get }

    /// Returns a cover image for the file at `url`, or `nil` if no cover is available.
    /// - Throws: if the file cannot be read or decoded.
    func coverImage(from url: URL) throws -> UIImage?
}

enum ThumbnailHandlers {
    static let all: [ThumbnailHandler] = [
        CbzThumbnailHandler(), CbrThumbnailHandler(), MmaThumbnailHandler()
    ]

    static func handler(forExtension ext: String) -> ThumbnailHandler? {
        let ext = ext.lowercased()
        return all.first { $0.supportedExtensions.contains(ext) }
    }
}
