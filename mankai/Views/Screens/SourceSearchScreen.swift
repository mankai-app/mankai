//
//  SourceSearchScreen.swift
//  mankai
//
//  Created by Travis XU on 27/6/2025.
//

import SwiftUI

struct SourceSearchScreen: View {
    let plugin: Plugin
    let query: String
    let isAuthorSearch: Bool
    let pluginService = PluginService.shared

    @State private var selectedGenre: SourceGenre
    @State private var selectedStatus: SourceStatusFilter?
    @State private var selectedSort: SourceSort

    @State var isLoading: Bool = false
    @State var mangas: [UInt: [Manga]] = [:]
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var readerRoute: ReaderRoute?

    private var supportsStatusFilter: Bool {
        plugin.supports(.search) && plugin.supports(.searchByStatus)
    }

    private var hasActiveFilters: Bool {
        selectedGenre != .default || selectedStatus != nil || selectedSort != .default
    }

    private var genreOptions: [SourceGenre] { plugin.searchGenreOptions }

    private var sortOptions: [SourceSort] { plugin.searchSortOptions }

    private var allMangas: [Manga] {
        let sortedKeys = mangas.keys.sorted()
        return sortedKeys.flatMap { mangas[$0] ?? [] }
    }

    init(
        plugin: Plugin, query: String, isAuthorSearch: Bool = false, genre: SourceGenre = .default,
        status: SourceStatusFilter? = nil, sortBy: SourceSort = .default
    ) {
        self.plugin = plugin
        self.query = query
        self.isAuthorSearch = isAuthorSearch
        let normalizedGenre = plugin.supportsSearch(genre: genre) ? genre : .default
        let normalizedStatus = plugin.supportsSearch(status: status) ? status : nil
        let normalizedSort = plugin.supportsSearch(sortBy: sortBy) ? sortBy : .default
        _selectedGenre = State(initialValue: normalizedGenre)
        _selectedStatus = State(initialValue: normalizedStatus)
        _selectedSort = State(initialValue: normalizedSort)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack {
                    MangasListView(mangas: allMangas, plugin: plugin, onRead: { readerRoute = $0 })
                        .id("mangasList")

                    if isLoading { ProgressView().frame(maxWidth: .infinity).padding() }

                    Color.clear.frame(height: 1).onAppear { search() }
                }
                .padding()
            }
            .onChange(of: selectedSort, initial: false) { _, _ in
                proxy.scrollTo("mangasList", anchor: .top)
            }
        }
        .overlay {
            if allMangas.isEmpty && isLoading {
                ProgressView()
            } else if allMangas.isEmpty && !mangas.isEmpty {
                ContentUnavailableView(
                    "noResultsFound", systemImage: "magnifyingglass",
                    description: Text("noResultsFoundDescription"))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitleWithSubtitle(title: Text(plugin.name ?? plugin.id), subtitle: Text(query))
        .navigationDestination(item: $readerRoute) { route in
            ReaderScreen(
                plugin: route.plugin, manga: route.manga, downloadManga: route.downloadManga,
                usesDownloadedMetadata: route.usesDownloadedMetadata,
                chapterGroupIndex: route.chapterGroupIndex, chapter: route.chapter,
                initialPage: route.initialPage)
        }
        .toolbar {
            if hasActiveFilters || genreOptions.count > 1 || supportsStatusFilter
                || sortOptions.count > 1
            {
                ToolbarItem(placement: .topBarTrailing) {
                    FilterButton(hasActiveFilters: hasActiveFilters, menu: filterMenuContent)
                }
            }
        }
        .onAppear { search() }.onReceive(pluginService.objectWillChange) { search() }
        .onChange(of: plugin.supportsSearch(genre: selectedGenre, sortBy: selectedSort)) {
            _, supported in if !supported { search() }
        }
        .onDisappear { searchTask?.cancel() }
        .alert("failedToSearchManga", isPresented: $showErrorAlert) {
            Button("ok") { errorMessage = "" }
        } message: {
            if !errorMessage.isEmpty { Text(errorMessage) }
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
        let normalizedGenre = plugin.supportsSearch(genre: genre) ? genre : .default
        let normalizedStatus = plugin.supportsSearch(status: status) ? status : nil
        let normalizedSort = plugin.supportsSearch(sortBy: sortBy) ? sortBy : .default
        guard
            selectedGenre != normalizedGenre || selectedStatus != normalizedStatus
                || selectedSort != normalizedSort
        else { return }

        searchTask?.cancel()
        selectedGenre = normalizedGenre
        selectedStatus = normalizedStatus
        selectedSort = normalizedSort
        mangas = [:]
        isLoading = false
        search()
    }

    private func search() {
        if selectedGenre != .default || selectedSort != .default,
            !plugin.supportsSearch(genre: selectedGenre, sortBy: selectedSort)
        {
            setFilters(genre: selectedGenre, status: selectedStatus, sortBy: selectedSort)
            return
        }

        if isLoading
            || !plugin.supportsSearch(
                isAuthor: isAuthorSearch, genre: selectedGenre, status: selectedStatus,
                sortBy: selectedSort)
        {
            return
        }

        let maxPage = mangas.keys.max() ?? 0

        // reach the end of the list
        if mangas[maxPage]?.count == 0 { return }

        let page = maxPage + 1
        let requestGenre = selectedGenre
        let requestStatus = selectedStatus
        let requestSort = selectedSort

        isLoading = true
        searchTask = Task {
            do {
                let result = try await plugin.search(
                    query, page: page, genre: requestGenre, status: requestStatus,
                    isAuthor: isAuthorSearch, sortBy: requestSort)

                guard !Task.isCancelled, requestGenre == selectedGenre,
                    requestStatus == selectedStatus, requestSort == selectedSort,
                    plugin.supportsSearch(
                        isAuthor: isAuthorSearch, genre: selectedGenre, status: selectedStatus,
                        sortBy: selectedSort)
                else { return }

                mangas[page] = result
                isLoading = false
            } catch is CancellationError {
                // Ignore requests cancelled by a filter change or view dismissal.
            } catch {
                guard !Task.isCancelled, requestGenre == selectedGenre,
                    requestStatus == selectedStatus, requestSort == selectedSort
                else { return }

                errorMessage = error.localizedDescription
                showErrorAlert = true
                isLoading = false
            }
        }
    }
}
