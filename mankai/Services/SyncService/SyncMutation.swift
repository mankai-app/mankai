//
//  SyncMutation.swift
//  mankai
//
//  Created by Travis XU on 5/10/2026.
//

import Foundation
import ReerCodable

@Codable struct SyncMutation: Equatable {
    enum Kind: String, Codable { case plugin, browsableplugin, library, progress }
    enum Action: String, Codable { case upsert, delete, clear }

    struct SourceKey: Codable, Equatable { var sourceId: String }

    struct MangaKey: Codable, Equatable {
        var sourceId: String
        var mangaId: String
    }

    struct PluginPayload: Codable, Equatable {
        var url: String
        var type: String
    }

    struct LibraryPayload: Codable, Equatable {
        var updates: Bool
        var latestChapter: Chapter
    }

    @Codable struct ProgressPayload: Equatable {
        var chapterId: String
        @CustomCoding<String?>(encode: { encoder, title in
            try encoder.set(title.map { AnyCodable($0) } ?? .null, forKey: "chapterTitle")
        }) var chapterTitle: String?
        var page: Int
    }

    @Decodable enum Entry: Equatable {
        @CodingCase(match: .string("plugin", at: "type")) case plugin(
            key: SourceKey, payload: PluginPayload?)

        @CodingCase(match: .string("browsableplugin", at: "type")) case browsableplugin(
            key: SourceKey, payload: PluginPayload?)

        @CodingCase(match: .string("library", at: "type")) case library(
            key: MangaKey, payload: LibraryPayload?)

        @CodingCase(match: .string("progress", at: "type")) case progress(
            key: MangaKey?, payload: ProgressPayload?)
    }

    var operationId: String?
    var action: Action
    var datetime: Int64

    // Flatten the typed entry and omit nil key/payload fields on deletes and clears.
    // ReerCodable's enum encoder writes nil associated values as null.
    @CustomCoding<Entry>(
        decode: { try Entry(from: $0) },
        encode: { encoder, entry in
            switch entry { case .plugin(let key, let payload):
                try encoder.set("plugin", forKey: "type")
                try encoder.set(key, forKey: "key")
                try encoder.set(payload, forKey: "payload")
                case .browsableplugin(let key, let payload):
                    try encoder.set("browsableplugin", forKey: "type")
                    try encoder.set(key, forKey: "key")
                    try encoder.set(payload, forKey: "payload")
                case .library(let key, let payload):
                    try encoder.set("library", forKey: "type")
                    try encoder.set(key, forKey: "key")
                    try encoder.set(payload, forKey: "payload")
                case .progress(let key, let payload):
                    try encoder.set("progress", forKey: "type")
                    try encoder.set(key, forKey: "key")
                    try encoder.set(payload, forKey: "payload")
            }
        }) var entry: Entry

    init(entry: Entry, action: Action = .upsert, date: Date = Date()) {
        operationId = UUID().uuidString
        self.entry = entry
        self.action = action
        datetime = Self.milliseconds(date)
    }

    init?(library: LibraryModel) {
        guard let chapter = library.latestChapter else { return nil }
        self.init(
            entry: .library(
                key: .init(sourceId: library.pluginId, mangaId: library.mangaId),
                payload: .init(updates: library.updates, latestChapter: chapter)),
            date: library.datetime)
    }

    @MainActor init?(plugin: Plugin, browsable: Bool = false) {
        guard plugin.supports(.urlEncoding), let type = plugin.syncType else { return nil }
        let key = SourceKey(sourceId: plugin.id)
        let payload = PluginPayload(url: plugin.encodeURL(), type: type)
        self.init(
            entry: browsable
                ? .browsableplugin(key: key, payload: payload) : .plugin(key: key, payload: payload)
        )
    }

    init(progress: ProgressModel) {
        self.init(
            entry: .progress(
                key: .init(sourceId: progress.pluginId, mangaId: progress.mangaId),
                payload: .init(
                    chapterId: progress.chapterId, chapterTitle: progress.chapterTitle,
                    page: progress.page)), date: progress.datetime)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        // Rounding keeps a downloaded millisecond unchanged after conversion through Date.
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    var date: Date { Date(timeIntervalSince1970: Double(datetime) / 1000) }

    var type: Kind {
        switch entry { case .plugin: return .plugin case .browsableplugin: return .browsableplugin
            case .library: return .library
            case .progress: return .progress
        }
    }

    var sourceId: String? {
        switch entry { case .plugin(let key, _), .browsableplugin(let key, _): return key.sourceId
            case .library(let key, _): return key.sourceId
            case .progress(let key, _): return key?.sourceId
        }
    }

    var mangaId: String? {
        switch entry { case .plugin, .browsableplugin: return nil case .library(let key, _):
            return key.mangaId
            case .progress(let key, _): return key?.mangaId
        }
    }

    func wins(over datetime: Int64, action: Action = .upsert) -> Bool {
        self.datetime > datetime
            || (self.datetime == datetime && self.action == .delete && action == .upsert)
    }

    func wins(over other: SyncMutation) -> Bool { wins(over: other.datetime, action: other.action) }

    var isValid: Bool {
        guard (0...9_007_199_254_740_991).contains(datetime) else { return false }
        switch entry { case .plugin(let key, let payload), .browsableplugin(let key, let payload):
            guard !key.sourceId.isEmpty else { return false }
            return action == .delete
                ? payload == nil
                : action == .upsert && payload?.url.isEmpty == false
                    && (payload?.type.utf16.count ?? 65) <= 64
                    && (payload?.url.utf16.count ?? 16385) <= 16384

            case .library(let key, let payload):
                guard !key.sourceId.isEmpty, !key.mangaId.isEmpty else { return false }
                return action == .delete
                    ? payload == nil
                    : action == .upsert && payload?.latestChapter.id.isEmpty == false
                        && (payload?.latestChapter.title?.utf16.count ?? 0) <= 1024

            case .progress(let key, let payload):
                if action == .clear { return key == nil && payload == nil }
                guard let key, !key.sourceId.isEmpty, !key.mangaId.isEmpty else { return false }
                if action == .delete { return payload == nil }
                guard let payload else { return false }
                return !payload.chapterId.isEmpty && payload.page >= 0
                    && (payload.chapterTitle?.utf16.count ?? 0) <= 1024
        }
    }
}
