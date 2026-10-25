//
//  FsParserFile.swift
//  mankai
//
//  Created by Travis XU on 3/8/2026.
//

import Foundation

struct FsParserFile: ParserFile {
    let cacheKey: String
    let url: URL

    var fileName: String { url.lastPathComponent }

    func getContent(progress: ParserFileProgress? = nil) async throws -> Data {
        progress?(nil)
        return try Data(contentsOf: url)
    }

    func getUrl(progress: ParserFileProgress? = nil) async throws -> URL {
        progress?(nil)
        return url
    }
}
