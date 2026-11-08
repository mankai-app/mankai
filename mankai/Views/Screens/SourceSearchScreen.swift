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

    @State var selectedGenre: SourceGenreFilter
    @State private var selectedStatus: Status

    @State var isLoading: Bool = false
    @State var mangas: [UInt: [Manga]] = [:]
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var readerRoute: ReaderRoute?

    private var supportsGenreFilter: Bool {
        plugin.supports(.search) && plugin.supports(.searchByGenre)
    }

    private var supportsCustomGenreFilter: Bool {
        plugin.supports(.search) && plugin.supports(.searchByCustomGenre)
    }

    private var supportsStatusFilter: Bool {
        plugin.supports(.search) && plugin.supports(.searchByStatus)
    }

    private var hasActiveFilters: Bool {
        selectedGenre != .standard(.all) || selectedStatus != .any
    }

    private var allMangas: [Manga] {
        let sortedKeys = mangas.keys.sorted()
        return sortedKeys.flatMap { mangas[$0] ?? [] }
    }

    init(
        plugin: Plugin, query: String, isAuthorSearch: Bool = false,
        genre: SourceGenreFilter = .standard(.all), status: Status = .any
    ) {
        self.plugin = plugin
        self.query = query
        self.isAuthorSearch = isAuthorSearch
        let normalizedGenre =
            plugin.supportsSearch(genre: genre.standardGenre, customGenre: genre.customGenre)
            ? genre : .standard(.all)
        let normalizedStatus =
            plugin.supports(.search) && plugin.supports(.searchByStatus) ? status : .any
        _selectedGenre = State(initialValue: normalizedGenre)
        _selectedStatus = State(initialValue: normalizedStatus)
    }

    var body: some View {
        ScrollView {
            LazyVStack {
                MangasListView(mangas: allMangas, plugin: plugin, onRead: { readerRoute = $0 })

                if isLoading { ProgressView().frame(maxWidth: .infinity).padding() }

                Color.clear.frame(height: 1).onAppear { search() }
            }
            .padding()
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
            if supportsGenreFilter || supportsCustomGenreFilter || supportsStatusFilter {
                ToolbarItem(placement: .topBarTrailing) {
                    FilterButton(hasActiveFilters: hasActiveFilters, menu: filterMenuContent)
                }
            }
        }
        .onAppear { search() }.onReceive(pluginService.objectWillChange) { search() }
        .onDisappear { searchTask?.cancel() }
        .alert("failedToSearchManga", isPresented: $showErrorAlert) {
            Button("ok") { errorMessage = "" }
        } message: {
            if !errorMessage.isEmpty { Text(errorMessage) }
        }
    }

    private var filterMenuContent: some View {
        SourceFilterMenuContent(
            plugin: plugin, supportsGenreFilter: supportsGenreFilter,
            supportsCustomGenreFilter: supportsCustomGenreFilter,
            supportsStatusFilter: supportsStatusFilter,
            genre: Binding(
                get: { selectedGenre }, set: { setFilters(genre: $0, status: selectedStatus) }),
            status: Binding(
                get: { selectedStatus }, set: { setFilters(genre: selectedGenre, status: $0) }),
            onReset: { setFilters(genre: .standard(.all), status: .any) })
    }

    private func setFilters(genre: SourceGenreFilter, status: Status) {
        let normalizedGenre =
            plugin.supportsSearch(genre: genre.standardGenre, customGenre: genre.customGenre)
            ? genre : .standard(.all)
        let normalizedStatus = supportsStatusFilter ? status : .any
        guard selectedGenre != normalizedGenre || selectedStatus != normalizedStatus else { return }

        searchTask?.cancel()
        selectedGenre = normalizedGenre
        selectedStatus = normalizedStatus
        mangas = [:]
        isLoading = false
        search()
    }

    private func search() {
        if isLoading
            || !plugin.supportsSearch(
                isAuthor: isAuthorSearch, genre: selectedGenre.standardGenre,
                status: selectedStatus, customGenre: selectedGenre.customGenre)
        {
            return
        }

        let maxPage = mangas.keys.max() ?? 0

        // reach the end of the list
        if mangas[maxPage]?.count == 0 { return }

        let page = maxPage + 1
        let requestGenre = selectedGenre
        let requestStatus = selectedStatus

        isLoading = true
        searchTask = Task {
            do {
                let result = try await plugin.search(
                    query, page: page, genre: requestGenre.standardGenre, status: requestStatus,
                    isAuthor: isAuthorSearch, customGenre: requestGenre.customGenre)

                guard !Task.isCancelled, requestGenre == selectedGenre,
                    requestStatus == selectedStatus,
                    plugin.supportsSearch(
                        isAuthor: isAuthorSearch, genre: selectedGenre.standardGenre,
                        status: selectedStatus, customGenre: selectedGenre.customGenre)
                else { return }

                mangas[page] = result
                isLoading = false
            } catch is CancellationError {
                // Ignore requests cancelled by a filter change or view dismissal.
            } catch {
                guard !Task.isCancelled, requestGenre == selectedGenre,
                    requestStatus == selectedStatus
                else { return }

                errorMessage = error.localizedDescription
                showErrorAlert = true
                isLoading = false
            }
        }
    }
}
