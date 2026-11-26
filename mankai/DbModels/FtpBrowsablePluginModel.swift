//
//  FtpBrowsablePluginModel.swift
//  mankai
//
//  Created by Travis XU on 26/11/2026.
//

import GRDB

extension FtpTransferProtocol: DatabaseValueConvertible {}

struct FtpBrowsablePluginModel {
    var id: String
    var name: String?
    var host: String
    var port: Int
    var username: String
    var password: String
    var shouldSync: Bool
    var transferProtocol: FtpTransferProtocol

    static func createTable(_ db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) {
            $0.primaryKey("id", .text)

            $0.column("name", .text)
            $0.column("host", .text).notNull()
            $0.column("port", .integer).notNull()
            $0.column("username", .text).notNull()
            $0.column("password", .text).notNull()
            $0.column("shouldSync", .boolean).notNull()
            $0.column("transferProtocol", .text).notNull()
        }
    }
}

extension FtpBrowsablePluginModel: TableRecord {
    static let databaseTableName = "ftpbrowsableplugin"
}

extension FtpBrowsablePluginModel: Codable, FetchableRecord, PersistableRecord {}
