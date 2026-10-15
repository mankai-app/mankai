//
//  DownloadChapterModel.swift
//  mankai
//
//  Created by Travis XU on 19/7/2025.
//

import Foundation
import GRDB

struct DownloadChapterModel {
    var id: String = UUID().uuidString
    var mangaId: String
    var chapterId: String
    var title: String?
    var completed: Bool = false
    var queueOrder: Int64

    static func createTable(_ db: Database) throws {
        try db.create(table: DownloadChapterModel.databaseTableName, ifNotExists: true) {
            $0.primaryKey("id", .text)

            $0.column("mangaId", .text).notNull()
            $0.column("chapterId", .text).notNull()
            $0.uniqueKey(["mangaId", "chapterId"])

            $0.column("title", .text)
            $0.column("completed", .boolean).notNull().indexed()
            $0.column("queueOrder", .integer).notNull().indexed()

            $0.foreignKey(
                ["mangaId"], references: DownloadMangaModel.databaseTableName, onDelete: .cascade)
        }
    }
}

extension DownloadChapterModel: TableRecord {
    static let databaseTableName = "chapter"

    static let manga = belongsTo(DownloadMangaModel.self)
    static let images = hasMany(DownloadImageModel.self)
}

extension DownloadChapterModel: Codable, FetchableRecord, PersistableRecord, Sendable {
    var manga: QueryInterfaceRequest<DownloadMangaModel> {
        request(for: DownloadChapterModel.manga)
    }

    var images: QueryInterfaceRequest<DownloadImageModel> {
        request(for: DownloadChapterModel.images)
    }
}
