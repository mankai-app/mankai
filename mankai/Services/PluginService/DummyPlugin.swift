//
//  DummyPlugin.swift
//  mankai
//
//  Created by Travis XU on 16/2/2026.
//

import Foundation

final class DummyPlugin: Plugin {
    private let _id: String

    override var id: String { _id }

    override var capabilities: [PluginCapability] { [.sync] }

    init(_ id: String) { _id = id }

    /// DummyPlugin cannot be saved
    override func savePlugin() throws {}

    override func deletePlugin() throws {}

    override func isOnline() async throws -> Bool {
        throw MankaiErrorCode.pluginDummyCannotBeUsed.makeError()
    }

    override func getSuggestions(_: String) async throws -> [String] {
        throw MankaiErrorCode.pluginDummyCannotBeUsed.makeError()
    }

    override func search(
        _: String, page _: UInt, genre _: Genre, status _: Status, isAuthor _: Bool
    ) async throws -> [Manga] { throw MankaiErrorCode.pluginDummyCannotBeUsed.makeError() }

    override func getList(page _: UInt, genre _: Genre, status _: Status) async throws -> [Manga] {
        throw MankaiErrorCode.pluginDummyCannotBeUsed.makeError()
    }

    override func getMangas(_: [String]) async throws -> [Manga] {
        throw MankaiErrorCode.pluginDummyCannotBeUsed.makeError()
    }

    override func getDetailedManga(_: String) async throws -> DetailedManga {
        throw MankaiErrorCode.pluginDummyCannotBeUsed.makeError()
    }

    override func getChapter(manga _: DetailedManga, chapter _: Chapter) async throws -> [String] {
        throw MankaiErrorCode.pluginDummyCannotBeUsed.makeError()
    }

    override func getImage(_: String) async throws -> Data {
        throw MankaiErrorCode.pluginDummyCannotBeUsed.makeError()
    }
}
