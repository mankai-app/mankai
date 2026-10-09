//
//  SuwayomiPluginModel.swift
//  mankai
//
//  Created by Travis XU on 9/10/2026.
//

import GRDB

struct SuwayomiPluginModel {
    var id: String
    var baseUrl: String
    var name: String
    var username: String
    var password: String
    var authMode: String

    static func createTable(_ db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) {
            $0.primaryKey("id", .text)

            $0.column("baseUrl", .text).notNull()
            $0.column("name", .text).notNull()
            $0.column("username", .text).notNull()
            $0.column("password", .text).notNull()
            $0.column("authMode", .text).notNull()
        }
    }
}

extension SuwayomiPluginModel: TableRecord { static let databaseTableName = "suwayomiplugin" }

extension SuwayomiPluginModel: Codable, FetchableRecord, PersistableRecord {}
