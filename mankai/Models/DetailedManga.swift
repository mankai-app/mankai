//
//  DetailedManga.swift
//  mankai
//
//  Created by Travis XU on 21/6/2025.
//

import Foundation
import ReerCodable

struct ChapterGroup: Codable {
    var id: String? = nil
    var title: String
    var chapters: [Chapter]
}

typealias ChapterGroups = [ChapterGroup]

@Codable struct DetailedManga: Identifiable {
    var id: String
    var title: String?
    var cover: String?
    var status: Status?
    var readingDirection: ReadingDirection?
    var latestChapter: Chapter?
    var description: String?
    var externalLink: String?
    @DateCoding(.millisecondsSince1970) var updatedAt: Date?
    @DecodingDefault([]) var authors: [String]
    @DecodingDefault([]) var genres: [Genre]
    @DecodingDefault([]) var customGenres: [String]
    @DecodingDefault([]) var chapters: ChapterGroups
    var remarks: String?
    var editable: Bool?

    var meta: String?

    init?(from any: Any) {
        guard let dict = any as? [String: Any], let decoded = try? Self.decoded(from: dict) else {
            return nil
        }
        self = decoded
    }

    init() {
        id = UUID().uuidString
        authors = []
        genres = []
        customGenres = []
        chapters = [
            ChapterGroup(title: "series", chapters: []), ChapterGroup(title: "extra", chapters: []),
            ChapterGroup(title: "volume", chapters: [])
        ]
        status = .onGoing
    }

    func toManga() -> Manga {
        Manga(
            id: id, title: title, cover: cover, status: status, latestChapter: latestChapter,
            updates: nil, meta: meta)
    }
}
