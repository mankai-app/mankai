//
//  HttpPluginModel.swift
//  mankai
//
//  Created by Travis XU on 19/7/2025.
//

import GRDB
import ReerCodable

@Codable struct HttpPluginModel {
    var id: String
    var baseUrl: String
    var meta: Metadata
    @DecodingDefault([]) var configValues: [ConfigValue]

    static func createTable(_ db: Database) throws {
        try db.create(table: HttpPluginModel.databaseTableName, ifNotExists: true) {
            $0.primaryKey("id", .text)

            $0.column("baseUrl", .text).notNull()
            $0.column("meta", .text).notNull()
            $0.column("configValues", .text).notNull()
        }
    }
}

extension HttpPluginModel: TableRecord { static let databaseTableName = "httpplugin" }

extension HttpPluginModel: FetchableRecord, PersistableRecord {}

extension HttpPluginModel {
    @Codable struct Metadata {
        let id: String
        let name: String?
        let version: String?
        let description: String?
        @DecodingDefault([]) let authors: [String]
        let repository: String?
        @DecodingDefault([]) let availableGenres: [Genre]
        let authenticationEnabled: Bool?
        @DecodingDefault(false) let editorEnabled: Bool
        @DecodingDefault([]) let configs: [Config]
        let cooldown: Cooldown?
        @DecodingDefault(PluginCapability.defaultCapabilities) let capabilities: [PluginCapability]
    }
}
