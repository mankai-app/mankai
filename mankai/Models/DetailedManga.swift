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
    /// Untagged groups are the fallback when no exact or broader language tag matches.
    var language: String? = nil
    var localizations: [String: ChapterLocalization]? = nil

    func localized(for language: String?) -> ChapterGroup {
        var group = self
        if let title = localizations?.localization(for: language)?.title { group.title = title }
        group.title = group.title.localizedChapterLabel
        group.chapters = chapters.map { $0.localized(for: language) }
        return group
    }
}

typealias ChapterGroups = [ChapterGroup]

/// Manga IDs stay fixed, chapter groups are selected by their own language.
@Codable struct DetailedMangaLocalization {
    var title: String?
    var cover: String?
    var status: Status?
    var readingDirection: ReadingDirection?
    var latestChapter: Chapter?
    var description: String?
    var externalLink: String?
    @DateCoding(.millisecondsSince1970) var updatedAt: Date?
    var authors: [String]?
    var genres: [Genre]?
    var customGenres: [String]?
    var remarks: String?
    var editable: Bool?
    var meta: String?

    func toMangaLocalization() -> MangaLocalization {
        MangaLocalization(
            title: title, cover: cover, status: status, latestChapter: latestChapter, meta: meta)
    }
}

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
    var localizations: [String: DetailedMangaLocalization]? = nil

    var availableLanguages: [String] {
        var languages = Set(localizations?.keys.map { $0 } ?? [])
        languages.formUnion(latestChapter?.localizations?.keys.map { $0 } ?? [])
        for group in chapters {
            if let language = group.language { languages.insert(language) }
            languages.formUnion(group.localizations?.keys.map { $0 } ?? [])
            for chapter in group.chapters {
                languages.formUnion(chapter.localizations?.keys.map { $0 } ?? [])
            }
        }
        return languages.sorted()
    }

    func localized(for language: String?) -> DetailedManga {
        var manga = self
        if let overrides = localizations?.localization(for: language) {
            manga.title = overrides.title ?? title
            manga.cover = overrides.cover ?? cover
            manga.status = overrides.status ?? status
            manga.readingDirection = overrides.readingDirection ?? readingDirection
            manga.latestChapter = overrides.latestChapter ?? latestChapter
            manga.description = overrides.description ?? description
            manga.externalLink = overrides.externalLink ?? externalLink
            manga.updatedAt = overrides.updatedAt ?? updatedAt
            manga.authors = overrides.authors ?? authors
            manga.genres = overrides.genres ?? genres
            manga.customGenres = overrides.customGenres ?? customGenres
            manga.remarks = overrides.remarks ?? remarks
            manga.editable = overrides.editable ?? editable
            manga.meta = overrides.meta ?? meta
        }
        manga.latestChapter = manga.latestChapter?.localized(for: language)
        manga.chapters = chapters.map { $0.localized(for: language) }
        return manga
    }

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
            updates: nil, meta: meta,
            localizations: localizations?.mapValues { $0.toMangaLocalization() })
    }
}
