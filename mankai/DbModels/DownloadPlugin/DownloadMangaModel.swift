//
//  DownloadMangaModel.swift
//  mankai
//
//  Created by Travis XU on 19/7/2025.
//

import Foundation
import GRDB

struct DownloadMangaModel {
    var pluginId: String
    var mangaId: String
    var id: String
    var sourceSnapshot: DetailedManga
    var chapters: ChapterGroups
    var isPaused: Bool = false

    var title: String? { sourceSnapshot.title }

    var cover: String? { sourceSnapshot.cover }

    static func makeId(pluginId: String, mangaId: String) -> String {
        "\(pluginId.utf8.count):\(pluginId)\(mangaId)"
    }

    static func createTable(_ db: Database) throws {
        try db.create(table: DownloadMangaModel.databaseTableName, ifNotExists: true) {
            $0.primaryKey("id", .text)

            $0.column("pluginId", .text).notNull().indexed()
            $0.column("mangaId", .text).notNull()
            $0.uniqueKey(["pluginId", "mangaId"])

            $0.column("sourceSnapshot", .text).notNull()
            $0.column("chapters", .text).notNull()
            $0.column("isPaused", .boolean).notNull()
        }
    }
}

extension DownloadMangaModel: TableRecord {
    static let databaseTableName = "manga"

    static let chapters = hasMany(DownloadChapterModel.self)
}

extension DownloadMangaModel: Codable, FetchableRecord, PersistableRecord, Sendable {
    var downloadChapters: QueryInterfaceRequest<DownloadChapterModel> {
        request(for: DownloadMangaModel.chapters)
    }
}
