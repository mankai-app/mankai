//
//  DownloadImageModel.swift
//  mankai
//
//  Created by Travis XU on 19/7/2025.
//

import Foundation
import GRDB

struct DownloadImageModel {
    var id: String = UUID().uuidString
    var url: String
    var mangaId: String

    // A nil chapterId identifies the manga cover.
    var chapterId: String?
    var pageIndex: Int?
    var completed: Bool = false

    var path: String { "images/\(id).image" }

    var reference: String {
        let ext = URL(string: url)?.pathExtension.lowercased() ?? ""
        let safeExtension =
            !ext.isEmpty && ext.count <= 10
                && ext.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) ? ext : "jpg"

        return "mankai-download://image/\(id).\(safeExtension)"
    }

    static func createTable(_ db: Database) throws {
        try db.create(table: DownloadImageModel.databaseTableName, ifNotExists: true) {
            $0.primaryKey("id", .text)

            $0.column("url", .text).notNull()
            $0.column("mangaId", .text).notNull().indexed()
            $0.column("chapterId", .text).indexed()
            $0.column("pageIndex", .integer)
            $0.uniqueKey(["chapterId", "pageIndex"])

            $0.column("completed", .boolean).notNull()

            $0.foreignKey(
                ["mangaId"], references: DownloadMangaModel.databaseTableName, onDelete: .cascade)

            $0.foreignKey(
                ["chapterId"], references: DownloadChapterModel.databaseTableName,
                onDelete: .cascade)
        }
    }
}

extension DownloadImageModel: TableRecord {
    static let databaseTableName = "downloadImage"

    static let manga = belongsTo(DownloadMangaModel.self)
    static let chapter = belongsTo(DownloadChapterModel.self)
}

extension DownloadImageModel: Codable, FetchableRecord, PersistableRecord, Sendable {
    var manga: QueryInterfaceRequest<DownloadMangaModel> { request(for: DownloadImageModel.manga) }

    var chapter: QueryInterfaceRequest<DownloadChapterModel> {
        request(for: DownloadImageModel.chapter)
    }
}
