//
//  SourceLibraryScreen.swift
//  mankai
//
//  Created by Travis XU on 27/6/2025.
//

import SwiftUI

struct SourceLibraryScreen: View {
    private struct ListKey: Hashable {
        let genre: SourceGenre
        let status: SourceStatusFilter?
        let sortBy: SourceSort
    }

    let plugin: Plugin

    @ObservedObject private var pluginService = PluginService.shared

    @State private var selectedGenre: SourceGenre
    @State private var selectedStatus: SourceStatusFilter?
    @State private var selectedSort: SourceSort = .default

    @State private var isLoading: Bool = false
    @State private var listLoadID = UUID()
    @State private var mangasList: [ListKey: [UInt: [Manga]]] = [:]
    @State private var showErrorAlert: Bool = false
    @State private var errorMessage: String = ""

    @State private var searchQuery: String = ""
    @State private var searchSuggestions: [String] = []
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var navigateToSearch: Bool = false
    @State private var readerRoute: ReaderRoute?
    @State private var isUpdateMangaModalPresented = false

    private var supportsStatusFilter: Bool {
        plugin.supports(.list) && plugin.supports(.listByStatus)
    }

    private var hasActiveFilters: Bool {
        selectedGenre != .default || selectedStatus != nil || selectedSort != .default
    }

    private var genreOptions: [SourceGenre] { plugin.listGenreOptions }

    private var sortOptions: [SourceSort] { plugin.listSortOptions }

    private var listKey: ListKey {
        ListKey(genre: selectedGenre, status: selectedStatus, sortBy: selectedSort)
    }

    init(plugin: Plugin, selectedGenre: SourceGenre = .default) {
        self.plugin = plugin
        let normalizedGenre = plugin.supportsList(genre: selectedGenre) ? selectedGenre : .default
        _selectedGenre = State(initialValue: normalizedGenre)
    }

    private var allMangas: [Manga] {
        guard let mangas = mangasList[listKey] else { return [] }

        let sortedKeys = mangas.keys.sorted()
        return sortedKeys.flatMap { mangas[$0] ?? [] }
    }

    private var hasLoadedCurrentFilter: Bool { mangasList[listKey] != nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack {
                    MangasListView(mangas: allMangas, plugin: plugin, onRead: { readerRoute = $0 })
                        .id("mangasList")

                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).padding()
                    }

                    Color.clear.frame(height: 1).onAppear { loadList() }
                }
                .padding()
            }
            .overlay {
                if allMangas.isEmpty && isLoading {
                    ProgressView()
                } else if allMangas.isEmpty && hasLoadedCurrentFilter {
                    ContentUnavailableView(
                        "noEntities", systemImage: "tray",
                        description: Text("noEntitiesDescription"))
                }
            }
            .onChange(of: listKey, initial: false) { _, _ in
                proxy.scrollTo("mangasList", anchor: .top)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $readerRoute) { route in
            ReaderScreen(
                plugin: route.plugin, manga: route.manga, downloadManga: route.downloadManga,
                usesDownloadedMetadata: route.usesDownloadedMetadata,
                chapterGroupIndex: route.chapterGroupIndex, chapter: route.chapter,
                initialPage: route.initialPage)
        }
        .capabilitySearchable(
            enabled: plugin.supports(.search), text: $searchQuery, prompt: "searchManga"
        ) {
            ForEach(searchSuggestions, id: \.self) { suggestion in
                Label(suggestion, systemImage: "magnifyingglass").foregroundColor(.secondary)
                    .searchCompletion(suggestion)
            }
        }
        .onSubmit(of: .search) { performSearch() }
        .onChange(of: searchQuery, initial: false) { _, newQuery in
            getSearchSuggestions(for: newQuery)
        }
        .onDisappear { searchTask?.cancel() }
        .navigationDestination(isPresented: $navigateToSearch) {
            SourceSearchScreen(
                plugin: plugin, query: searchQuery, genre: selectedGenre, status: selectedStatus,
                sortBy: selectedSort)
        }
        .sheet(isPresented: $isUpdateMangaModalPresented) {
            if let editablePlugin = plugin as? any Editable {
                UpdateMangaModal(plugin: editablePlugin, showSourceSelection: false)
            }
        }
        .toolbar {
            if plugin is any Editable {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { isUpdateMangaModalPresented = true }) {
                        ToolbarIcon(systemName: "plus", legacySystemName: "plus.circle")
                    }
                }
            }

            if hasActiveFilters || genreOptions.count > 1 || supportsStatusFilter
                || sortOptions.count > 1
            {
                ToolbarItem(placement: .topBarTrailing) {
                    FilterButton(hasActiveFilters: hasActiveFilters, menu: filterMenuContent)
                }
            }
        }
        .navigationTitleWithSubtitle(
            title: Text(plugin.name ?? plugin.id), subtitle: Text("library")
        )
        .onAppear { loadList() }.onReceive(plugin.objectWillChange) { reloadList() }
        .onChange(of: plugin.supportsList(genre: selectedGenre, sortBy: selectedSort)) {
            _, supported in if !supported { reloadList() }
        }
        .alert("failedToLoadList", isPresented: $showErrorAlert) {
            Button("ok") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func reloadList() {
        listLoadID = UUID()
        mangasList = [:]
        isLoading = false
        if !plugin.supportsList(genre: selectedGenre) { selectedGenre = .default }
        if !plugin.supportsList(sortBy: selectedSort) { selectedSort = .default }
        loadList()
    }

    private func loadList() {
        if isLoading
            || !plugin.supportsList(
                genre: selectedGenre, status: selectedStatus, sortBy: selectedSort)
        {
            return
        }

        let key = listKey

        let maxPage = mangasList[key]?.keys.max() ?? 0

        // reach the end of the list
        if mangasList[key]?[maxPage]?.count == 0 { return }

        let page = maxPage + 1

        let loadID = listLoadID

        isLoading = true
        Task {
            do {
                let result = try await plugin.getList(
                    page: page, genre: key.genre, status: key.status, sortBy: key.sortBy)
                guard loadID == listLoadID else { return }

                if mangasList[key] == nil { mangasList[key] = [:] }

                mangasList[key]![page] = result

                isLoading = false
            } catch {
                guard loadID == listLoadID else { return }
                isLoading = false
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    private var filterMenuContent: some View {
        SourceFilterMenuContent(
            genreOptions: genreOptions, supportsStatusFilter: supportsStatusFilter,
            sortOptions: sortOptions,
            genre: Binding(
                get: { selectedGenre },
                set: { setFilters(genre: $0, status: selectedStatus, sortBy: selectedSort) }),
            status: Binding(
                get: { selectedStatus },
                set: { setFilters(genre: selectedGenre, status: $0, sortBy: selectedSort) }),
            sortBy: Binding(
                get: { selectedSort },
                set: { setFilters(genre: selectedGenre, status: selectedStatus, sortBy: $0) }),
            onReset: { setFilters(genre: .default, status: nil, sortBy: .default) })
    }

    private func setFilters(genre: SourceGenre, status: SourceStatusFilter?, sortBy: SourceSort) {
        let normalizedGenre = plugin.supportsList(genre: genre) ? genre : .default
        let normalizedStatus = plugin.supportsList(status: status) ? status : nil
        let normalizedSort = plugin.supportsList(sortBy: sortBy) ? sortBy : .default

        if selectedGenre != normalizedGenre || selectedStatus != normalizedStatus
            || selectedSort != normalizedSort
        {
            listLoadID = UUID()
            isLoading = false
            selectedGenre = normalizedGenre
            selectedStatus = normalizedStatus
            selectedSort = normalizedSort
        }

        loadList()
    }

    private func getSearchSuggestions(for query: String) {
        searchTask?.cancel()

        guard plugin.supports(.search), plugin.supports(.suggestions), !query.isEmpty else {
            searchSuggestions = []
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))

            guard !Task.isCancelled else { return }

            do {
                let suggestions = try await plugin.getSuggestions(query)
                guard !Task.isCancelled else { return }
                searchSuggestions = suggestions
            } catch { searchSuggestions = [] }
        }
    }

    private func performSearch() {
        guard plugin.supports(.search), !searchQuery.isEmpty else { return }
        navigateToSearch = true
    }
}
