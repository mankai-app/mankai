//
//  SearchScreen.swift
//  mankai
//
//  Created by Travis XU on 27/6/2025.
//

import SwiftUI

struct SearchScreen: View {
    let query: String
    let pluginService = PluginService.shared
    @AppStorage(SettingsKey.hideBuiltInPlugins.rawValue) private var hideBuiltInPlugins: Bool =
        SettingsDefaults.hideBuiltInPlugins

    @State private var plugins: [Plugin] = []
    @State private var readerRoute: ReaderRoute?

    var body: some View {
        ScrollView {
            LazyVStack {
                ForEach(plugins) { plugin in
                    SourceSearchMangasRowListView(
                        query: query, plugin: plugin, onRead: { readerRoute = $0 })
                }
            }
            .padding()
        }
        .scrollClipDisabled()
        .navigationDestination(item: $readerRoute) { route in
            ReaderScreen(
                plugin: route.plugin, manga: route.manga, downloadManga: route.downloadManga,
                usesDownloadedMetadata: route.usesDownloadedMetadata,
                chapterGroupIndex: route.chapterGroupIndex, chapter: route.chapter,
                initialPage: route.initialPage)
        }
        .overlay {
            if plugins.isEmpty {
                ContentUnavailableView(
                    "noSourceAvailable", systemImage: "puzzlepiece.extension",
                    description: Text("noSourceAvailableDescription"))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitleWithSubtitle(title: Text("search"), subtitle: Text(query))
        .onAppear { updatePlugins() }.onReceive(pluginService.objectWillChange) { updatePlugins() }
        .onChange(of: hideBuiltInPlugins) { updatePlugins() }
    }

    private func updatePlugins() {
        plugins = pluginService.plugins.filter { plugin in
            plugin.supports(.search) && (!hideBuiltInPlugins || !(plugin is AppDirPlugin))
        }
    }
}

struct SourceSearchMangasRowListView: View {
    let query: String

    @ObservedObject var plugin: Plugin
    let onRead: (ReaderRoute) -> Void
    @State var mangas: [Manga]? = nil
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    func loadMangas() {
        guard plugin.supportsSearch() else {
            mangas = []
            return
        }

        Task {
            do { mangas = try await plugin.search(query, page: 1, genre: .all, status: .any) } catch
            {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    var body: some View {
        MangasRowListView(mangas: mangas, plugin: plugin, query: query, onRead: onRead)
            .onAppear { loadMangas() }.onReceive(plugin.objectWillChange) { loadMangas() }
            .alert("failedToSearchManga", isPresented: $showErrorAlert) {
                Button("ok") { errorMessage = "" }
            } message: {
                if !errorMessage.isEmpty { Text(errorMessage) }
            }
    }
}
