//
//  SyncQueueModel.swift
//  mankai
//
//  Created by Travis XU on 5/10/2026.
//

import Foundation
import GRDB

/// One pending mutation per key. Uploaded operations are deleted by operation ID.
struct SyncQueueModel {
    var type: SyncMutation.Kind
    var sourceId: String
    var mangaId: String
    var datetime: Int64
    var operationId: String
    var mutation: SyncMutation

    init(_ mutation: SyncMutation) {
        type = mutation.type
        sourceId = mutation.sourceId ?? ""
        mangaId = mutation.mangaId ?? ""
        datetime = mutation.datetime
        operationId = mutation.operationId ?? UUID().uuidString
        self.mutation = mutation
        self.mutation.operationId = operationId
    }

    static func request(for mutation: SyncMutation) -> QueryInterfaceRequest<Self> {
        filter(
            Column("type") == mutation.type.rawValue
                && Column("sourceId") == (mutation.sourceId ?? "")
                && Column("mangaId") == (mutation.mangaId ?? ""))
    }

    static var progressClear: QueryInterfaceRequest<Self> {
        filter(Column("type") == "progress" && Column("sourceId") == "")
    }

    static func createTable(_ db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) {
            $0.primaryKey(["type", "sourceId", "mangaId"])
            $0.column("type", .text).notNull()
            $0.column("sourceId", .text).notNull()
            $0.column("mangaId", .text).notNull()
            $0.column("datetime", .integer).notNull()
            $0.column("operationId", .text).notNull()
            $0.column("mutation", .text).notNull()
        }
    }
}

extension SyncQueueModel: TableRecord { static let databaseTableName = "syncQueue" }

extension SyncQueueModel: Codable, FetchableRecord, PersistableRecord {}
