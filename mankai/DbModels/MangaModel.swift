//
//  MangaModel.swift
//  mankai
//
//  Created by Travis XU on 19/7/2025.
//

import GRDB

struct MangaModel {
    var mangaId: String
    var pluginId: String
    var info: Manga

    static func createTable(_ db: Database) throws {
        try db.create(table: MangaModel.databaseTableName, ifNotExists: true) {
            $0.primaryKey(["mangaId", "pluginId"])

            $0.column("mangaId", .text).notNull()
            $0.column("pluginId", .text).notNull()
            $0.column("info", .text).notNull()
        }
    }
}

extension MangaModel: TableRecord { static let databaseTableName = "manga" }

extension MangaModel: Codable, FetchableRecord, PersistableRecord {}
