//
//  LibraryModel.swift
//  mankai
//
//  Created by Travis XU on 19/7/2025.
//

import Foundation
import GRDB

struct LibraryModel {
    var mangaId: String
    var pluginId: String
    var datetime: Date
    var updates: Bool
    var latestChapter: Chapter?

    var shouldSync: Bool = true

    static func createTable(_ db: Database) throws {
        try db.create(table: LibraryModel.databaseTableName, ifNotExists: true) {
            $0.primaryKey(["mangaId", "pluginId"])

            $0.column("mangaId", .text).notNull()
            $0.column("pluginId", .text).notNull()
            $0.column("datetime", .datetime).notNull()
            $0.column("updates", .boolean).notNull()
            $0.column("latestChapter", .text)

            $0.column("shouldSync", .boolean).notNull().defaults(to: true)
        }
    }
}

extension LibraryModel: TableRecord { static let databaseTableName = "library" }

extension LibraryModel: Codable, FetchableRecord, PersistableRecord {}
