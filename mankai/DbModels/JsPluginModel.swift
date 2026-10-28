//
//  JsPluginModel.swift
//  mankai
//
//  Created by Travis XU on 19/7/2025.
//

import GRDB
import ReerCodable

@Codable struct JsPluginModel {
    var id: String
    var meta: Metadata
    @DecodingDefault([]) var configValues: [ConfigValue]
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

extension JsPluginModel: FetchableRecord, PersistableRecord {}

extension JsPluginModel {
    @Codable struct Metadata {
        let id: String
        let name: String?
        let version: String?
        let description: String?
        @DecodingDefault([]) let authors: [String]
        let repository: String?
        let icon: String?
        let homePage: String?
        let updatesUrl: String?
        @DecodingDefault([]) let availableGenres: [Genre]
        @DecodingDefault([:]) let scripts: [String: String]
        @DecodingDefault([]) let configs: [Config]
        let getImageHeaders: [String: String]?
        let cooldown: Cooldown?
        @DecodingDefault(PluginCapability.defaultCapabilities) let capabilities: [PluginCapability]
    }
}
