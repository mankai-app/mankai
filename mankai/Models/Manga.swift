//
//  Manga.swift
//  mankai
//
//  Created by Travis XU on 21/6/2025.
//

import Foundation
import ReerCodable

enum Genre: String, Codable, CaseIterable {
    case all
    case action
    case romance
    case yuri
    case boysLove
    case otokonoko
    case schoolLife
    case adventure
    case harem
    case speculativeFiction
    case war
    case suspense
    case fanFiction
    case comedy
    case magic
    case horror
    case historical
    case sports
    case mature
    case mecha
}

@Codable enum Status: Int {
    case any = 0
    case onGoing = 1
    case completed = 2

    var localizedName: String {
        switch self { case .any: return String(localized: "any") case .onGoing:
            return String(localized: "onGoing")
            case .completed: return String(localized: "mangaCompleted")
        }
    }
}

struct Chapter: Codable, Equatable {
    var id: String
    var title: String?
    var locked: Bool?
}

struct MangaUpdateRequest: Codable {
    var id: String
    var latestChapter: Chapter
}

@Codable struct Manga: Identifiable {
    var id: String
    var title: String?
    var cover: String?
    var status: Status?
    var latestChapter: Chapter?
    /// Present on `getMangaUpdates` results and controls whether the library entry is marked updated.
    var updates: Bool?

    var meta: String?

    init?(from any: Any) {
        guard let dict = any as? [String: Any], let decoded = try? Self.decoded(from: dict) else {
            return nil
        }
        self = decoded
    }
}
