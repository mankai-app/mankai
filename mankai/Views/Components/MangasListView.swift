//
//  MangasListView.swift
//  mankai
//
//  Created by Travis XU on 28/6/2025.
//

import SwiftUI

struct MangasListView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let mangas: [Manga]?
    let plugin: Plugin?
    let mangasDict: [String: Manga]?
    let pluginsDict: [String: Plugin]?
    let keys: [String]?
    let progressEntries: [String: ProgressModel]?
    let libraryItems: [String: LibraryModel]?
    let showsUnreadTag: Bool
    let allowUnsupportedDetailsNavigation: Bool

    /// Simple initializer for single plugin case
    init(mangas: [Manga], plugin: Plugin) {
        self.mangas = mangas
        self.plugin = plugin
        mangasDict = nil
        pluginsDict = nil
        keys = nil
        progressEntries = nil
        libraryItems = nil
        showsUnreadTag = false
        allowUnsupportedDetailsNavigation = false
    }

    /// Complex initializer for multiple plugins with progress and library states
    init(
        mangas: [String: Manga], plugins: [String: Plugin], keys: [String],
        progressEntries: [String: ProgressModel]? = nil,
        libraryItems: [String: LibraryModel]? = nil, showsUnreadTag: Bool = false,
        allowUnsupportedDetailsNavigation: Bool = false
    ) {
        self.mangas = nil
        plugin = nil
        mangasDict = mangas
        pluginsDict = plugins
        self.keys = keys
        self.progressEntries = progressEntries
        self.libraryItems = libraryItems
        self.showsUnreadTag = showsUnreadTag
        self.allowUnsupportedDetailsNavigation = allowUnsupportedDetailsNavigation
    }

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: horizontalSizeClass == .regular ? 140 : 110), spacing: 12,
                    alignment: .top)
            ], spacing: 12
        ) {
            if let mangas = mangas, let plugin = plugin {
                // Simple case: array of mangas with single plugin
                ForEach(mangas, id: \.id) { manga in
                    if plugin.supports(.mangaDetails) {
                        NavigationLink(
                            destination: MangaDetailsScreen(plugin: plugin, manga: manga)
                        ) { MangaItemView(manga: manga, plugin: plugin) }
                    } else {
                        MangaItemView(manga: manga, plugin: plugin)
                    }
                }
            } else if let mangasDict = mangasDict, let pluginsDict = pluginsDict, let keys = keys {
                // Complex case: dictionaries with keys
                ForEach(keys, id: \.self) { key in
                    if let manga = mangasDict[key], let plugin = pluginsDict[key] {
                        if plugin.supports(.mangaDetails) || allowUnsupportedDetailsNavigation {
                            NavigationLink(
                                destination: MangaDetailsScreen(plugin: plugin, manga: manga)
                            ) {
                                MangaItemView(
                                    manga: manga, plugin: plugin, progress: progressEntries?[key],
                                    libraryItem: libraryItems?[key], showsUnreadTag: showsUnreadTag)
                            }
                        } else {
                            MangaItemView(
                                manga: manga, plugin: plugin, progress: progressEntries?[key],
                                libraryItem: libraryItems?[key], showsUnreadTag: showsUnreadTag)
                        }
                    }
                }
            }
        }
    }
}
