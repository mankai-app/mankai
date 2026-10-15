//
//  FsMangaModel.swift
//  mankai
//
//  Created by Travis XU on 19/7/2025.
//

import Foundation
import GRDB

struct FsMangaModel {
    var id: String
    var title: String?
    var status: Int?
    var description: String?
    var updatedAt: Date?
    var authors: [String]
    var genres: [Genre]
    var latestChapterId: Int?

    static func createTable(_ db: Database) throws {
        try db.create(table: FsMangaModel.databaseTableName, ifNotExists: true) {
            $0.primaryKey("id", .text)

            $0.column("title", .text)
            $0.column("status", .integer)
            $0.column("description", .text)
            $0.column("updatedAt", .datetime)
            $0.column("authors", .text)
            $0.column("genres", .text)
            $0.column("latestChapterId", .integer)
        }
    }
}

extension FsMangaModel: TableRecord {
    static let databaseTableName = "manga"

    static let cover = hasOne(FsImageModel.self)
    static let chapters = hasMany(FsChapterGroupModel.self)
}

extension FsMangaModel: Codable, FetchableRecord, PersistableRecord {
    var cover: QueryInterfaceRequest<FsImageModel> { request(for: FsMangaModel.cover) }

    var chapters: QueryInterfaceRequest<FsChapterGroupModel> { request(for: FsMangaModel.chapters) }

    var latestChapter: QueryInterfaceRequest<FsChapterModel> {
        FsChapterModel.filter(key: latestChapterId)
    }
}
