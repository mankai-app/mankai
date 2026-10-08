//
//  LibraryTab.swift
//  mankai
//
//  Created by Travis XU on 21/6/2025.
//

import SwiftUI

struct LibraryTab: View {
    let pluginService = PluginService.shared
    @AppStorage(SettingsKey.hideBuiltInPlugins.rawValue) private var hideBuiltInPlugins: Bool =
        SettingsDefaults.hideBuiltInPlugins
    @State var plugins: [Plugin] = []

    @State var query: String = ""
    @State var searchSuggestions: [String] = []
    @State var searchTask: Task<Void, Never>? = nil
    @State var navigateToSearch: Bool = false
    @State private var isUpdateMangaModalPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if plugins.isEmpty {
                    ContentUnavailableView(
                        "noSourceAvailable", systemImage: "puzzlepiece.extension",
                        description: Text("noSourceAvailableDescription"))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(plugins) { plugin in SourceListMangasRowListView(plugin: plugin)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("library").onAppear { updatePlugins() }
            .onReceive(pluginService.objectWillChange) { updatePlugins() }
            .onChange(of: hideBuiltInPlugins) {
                updatePlugins()
                getSearchSuggestions(for: query)
            }
            .capabilitySearchable(
                enabled: !searchablePlugins.isEmpty, text: $query, prompt: "searchManga"
            ) {
                ForEach(searchSuggestions, id: \.self) { suggestion in
                    Label(suggestion, systemImage: "magnifyingglass").foregroundColor(.secondary)
                        .searchCompletion(suggestion)
                }
            }
            .onSubmit(of: .search) { performSearch() }
            .onChange(of: query, initial: false) { _, newQuery in
                getSearchSuggestions(for: newQuery)
            }
            .onDisappear { searchTask?.cancel() }
            .navigationDestination(
                isPresented: $navigateToSearch, destination: { SearchScreen(query: query) }
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { isUpdateMangaModalPresented = true }) {
                        ToolbarIcon(systemName: "plus", legacySystemName: "plus.circle")
                    }
                }
            }
            .sheet(isPresented: $isUpdateMangaModalPresented) { UpdateMangaModal() }
        }
    }

    private func updatePlugins() {
        plugins = pluginService.plugins
            .filter { plugin in
                guard plugin.supports(.list) else { return false }

                if hideBuiltInPlugins, plugin is AppDirPlugin { return false }
                return true
            }
            .sorted { plugin1, plugin2 in
                let name1 = plugin1.name ?? plugin1.id
                let name2 = plugin2.name ?? plugin2.id
                return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
            }
    }

    private func getSearchSuggestions(for query: String) {
        // Cancel previous search task
        searchTask?.cancel()

        guard !query.isEmpty else {
            searchSuggestions = []
            return
        }

        searchTask = Task {
            // Add debouncing delay
            try? await Task.sleep(for: .milliseconds(300))

            guard !Task.isCancelled else { return }

            var allSuggestions: Set<String> = []

            // Get suggestions from all available plugins
            for plugin in searchablePlugins where plugin.supports(.suggestions) {
                guard !Task.isCancelled else { break }

                do {
                    let suggestions = try await plugin.getSuggestions(query)
                    allSuggestions.formUnion(suggestions)
                } catch {
                    // Continue with other plugins if one fails
                    Logger.pluginService.error(
                        "Failed to get suggestions from plugin \(plugin.id)", error: error)
                }
            }

            guard !Task.isCancelled else { return }

            self.searchSuggestions = Array(allSuggestions)
        }
    }

    private func performSearch() {
        guard !query.isEmpty, !searchablePlugins.isEmpty else { return }
        navigateToSearch = true
    }

    private var searchablePlugins: [Plugin] {
        pluginService.plugins.filter { plugin in
            plugin.supports(.search) && (!hideBuiltInPlugins || !(plugin is AppDirPlugin))
        }
    }
}

extension View {
    @ViewBuilder func capabilitySearchable<Suggestions: View>(
        enabled: Bool, text: Binding<String>, prompt: LocalizedStringKey,
        @ViewBuilder suggestions: () -> Suggestions
    ) -> some View {
        if enabled {
            searchable(text: text, prompt: prompt, suggestions: suggestions)
        } else {
            self
        }
    }
}

private struct SourceListMangasRowListView: View {
    @ObservedObject var plugin: Plugin
    @State var mangas: [Manga]? = nil
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    func loadMangas() {
        guard plugin.supportsList() else {
            mangas = []
            return
        }

        Task {
            do {
                mangas = try await plugin.getList(page: 1, genre: .all, status: .any)

            } catch {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    var body: some View {
        MangasRowListView(mangas: mangas, plugin: plugin).onAppear { loadMangas() }
            .onReceive(plugin.objectWillChange) { loadMangas() }
            .alert("failedToLoadMangas", isPresented: $showErrorAlert) {
                Button("ok") { errorMessage = "" }
            } message: {
                if !errorMessage.isEmpty { Text(errorMessage) }
            }
    }
}
