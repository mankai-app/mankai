//
//  OpdsBrowsableBookModel.swift
//  mankai
//
//  Created by Travis XU on 20/8/2026.
//

import GRDB

struct OpdsBrowsableBookModel {
    var pluginId: String
    var bookId: String
    var info: OpdsBookEntry

    static func createTable(_ db: Database) throws {
        try db.create(table: OpdsBrowsableBookModel.databaseTableName, ifNotExists: true) {
            $0.primaryKey(["pluginId", "bookId"])

            $0.column("pluginId", .text).notNull()
            $0.column("bookId", .text).notNull()
            $0.column("info", .text).notNull()
        }
    }
}

extension OpdsBrowsableBookModel: TableRecord { static let databaseTableName = "opdsbrowsablebook" }

extension OpdsBrowsableBookModel: Codable, FetchableRecord, PersistableRecord {}
