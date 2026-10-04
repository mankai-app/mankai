//
//  OpdsParserFile.swift
//  mankai
//
//  Created by Travis XU on 20/8/2026.
//

import Foundation

struct OpdsParserFile: ParserFile {
    let cacheKey: String
    let fileName: String

    private let remoteURL: URL
    private let session: OpdsSession
    private let temporaryDirectory: URL

    init(
        cacheKey: String, remoteURL: URL, fileName: String, session: OpdsSession,
        temporaryDirectory: URL
    ) {
        self.cacheKey = cacheKey
        self.remoteURL = remoteURL
        self.fileName = fileName
        self.session = session
        self.temporaryDirectory = temporaryDirectory
    }

    func getContent() async throws -> Data {
        let localURL = try await localURL()
        return try Data(contentsOf: localURL)
    }

    func getUrl() async throws -> URL { try await localURL() }

    private func localURL() async throws -> URL {
        let localURL = FileUtilities.cacheURL(
            for: "\(cacheKey)/\(fileName)", in: temporaryDirectory)
        return try await ParserFileDownloadRegistry.shared.file(at: localURL) {
            [session, remoteURL] localURL in
            Logger.opdsBrowsablePlugin.info("Downloading OPDS parser file: \(remoteURL)")
            let data = try await session.download(url: remoteURL)
            try Task.checkCancellation()
            try data.write(to: localURL, options: .atomic)
            Logger.opdsBrowsablePlugin.info("Downloaded OPDS parser file: \(remoteURL)")
        }
    }
}
