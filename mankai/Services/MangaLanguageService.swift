//
//  MangaLanguageService.swift
//  mankai
//
//  Created by Travis XU on 1/11/2026.
//

import Combine
import Foundation

@MainActor final class MangaLanguageService: ObservableObject {
    static let shared = MangaLanguageService()

    @Published private(set) var languages: [String: [String: String]]

    private init() {
        languages =
            UserDefaults.standard.dictionary(forKey: SettingsKey.mangaLanguages.rawValue)
            as? [String: [String: String]] ?? [:]
    }

    /// `nil` selects Auto, an empty string selects Default Language.
    func language(mangaId: String, pluginId: String) -> String? { languages[pluginId]?[mangaId] }

    func preferredLanguage(mangaId: String, pluginId: String) -> String? {
        if let selected = language(mangaId: mangaId, pluginId: pluginId) {
            return selected.isEmpty ? nil : selected
        }
        return Bundle.main.preferredLocalizations.first
    }

    func setLanguage(_ language: String?, mangaId: String, pluginId: String) {
        languages[pluginId, default: [:]][mangaId] = language
        UserDefaults.standard.set(languages, forKey: SettingsKey.mangaLanguages.rawValue)
    }

    func clearCache() {
        languages = [:]
        UserDefaults.standard.removeObject(forKey: SettingsKey.mangaLanguages.rawValue)
    }

    func localized(_ manga: Manga, plugin: Plugin) -> Manga {
        manga.localized(for: preferredLanguage(mangaId: manga.id, pluginId: plugin.id))
    }

    func localized(_ manga: DetailedManga, plugin: Plugin) -> DetailedManga {
        manga.localized(for: preferredLanguage(mangaId: manga.id, pluginId: plugin.id))
    }
}
