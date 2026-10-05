//
//  JsPluginModel.swift
//  mankai
//
//  Created by Travis XU on 19/7/2025.
//

import GRDB

struct JsPluginModel {
    var id: String
    var meta: String
    var configValues: String
    var sourceURL: String? = nil

    static func createTable(_ db: Database) throws {
        try db.create(table: JsPluginModel.databaseTableName, ifNotExists: true) {
            $0.primaryKey("id", .text)

            $0.column("meta", .text).notNull()
            $0.column("configValues", .text).notNull()
            $0.column("sourceURL", .text)
        }
    }
}

extension JsPluginModel: TableRecord { static let databaseTableName = "jsplugin" }

extension JsPluginModel: Codable, FetchableRecord, PersistableRecord {}
