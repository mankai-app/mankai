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

    @State var selectedGenre: Genre
    @State private var selectedStatus: Status
    @State private var showingFilters = false

    @State private var tempSelectedGenre: Genre
    @State private var tempSelectedStatus: Status

    @State var isLoading: Bool = false
    @State var mangas: [UInt: [Manga]] = [:]
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var searchTask: Task<Void, Never>?

    private var supportsGenreFilter: Bool {
        plugin.supports(.search) && plugin.supports(.searchByGenre)
    }

    private var supportsStatusFilter: Bool {
        plugin.supports(.search) && plugin.supports(.searchByStatus)
    }

    private var hasActiveFilters: Bool { selectedGenre != .all || selectedStatus != .any }

    private var allMangas: [Manga] {
        let sortedKeys = mangas.keys.sorted()
        return sortedKeys.flatMap { mangas[$0] ?? [] }
    }

    init(
        plugin: Plugin, query: String, isAuthorSearch: Bool = false, genre: Genre = .all,
        status: Status = .any
    ) {
        self.plugin = plugin
        self.query = query
        self.isAuthorSearch = isAuthorSearch
        let normalizedGenre =
            plugin.supports(.search) && plugin.supports(.searchByGenre) ? genre : .all
        let normalizedStatus =
            plugin.supports(.search) && plugin.supports(.searchByStatus) ? status : .any
        _selectedGenre = State(initialValue: normalizedGenre)
        _selectedStatus = State(initialValue: normalizedStatus)
        _tempSelectedGenre = State(initialValue: normalizedGenre)
        _tempSelectedStatus = State(initialValue: normalizedStatus)
    }

    var body: some View {
        ScrollView {
            LazyVStack {
                MangasListView(mangas: allMangas, plugin: plugin)

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
        .toolbar {
            if supportsGenreFilter || supportsStatusFilter {
                ToolbarItem(placement: .primaryAction) {
                    FilterButton(hasActiveFilters: hasActiveFilters) { showingFilters = true }
                }
            }
        }
        .sheet(isPresented: $showingFilters) {
            NavigationView {
                List {
                    Section {
                        if supportsGenreFilter {
                            Picker("genre", selection: $tempSelectedGenre) {
                                Text(LocalizedStringKey(Genre.all.rawValue)).tag(Genre.all)

                                ForEach(plugin.availableGenres, id: \.self) { genre in
                                    Text(LocalizedStringKey(genre.rawValue)).tag(genre)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        if supportsStatusFilter {
                            Picker("status", selection: $tempSelectedStatus) {
                                Text(Status.any.localizedName).tag(Status.any)
                                Text(Status.onGoing.localizedName).tag(Status.onGoing)
                                Text(Status.completed.localizedName).tag(Status.completed)
                            }
                            .pickerStyle(.menu)
                        }
                    } header: {
                        Spacer(minLength: 0)
                    }

                    Section {
                        Button(
                            "reset", role: .destructive,
                            action: {
                                resetFilters()
                                showingFilters = false
                            })
                    }
                }
                .navigationTitle("filters").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: {
                            tempSelectedGenre = selectedGenre
                            tempSelectedStatus = selectedStatus
                            showingFilters = false
                        }) { Text("cancel") }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: {
                            setFilters(genre: tempSelectedGenre, status: tempSelectedStatus)
                            showingFilters = false
                        }) { Text("done") }
                    }
                }
            }
            .presentationDetents([.medium])
            .onAppear {
                tempSelectedGenre = selectedGenre
                tempSelectedStatus = selectedStatus
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

    private func setFilters(genre: Genre, status: Status) {
        let normalizedGenre = supportsGenreFilter ? genre : .all
        let normalizedStatus = supportsStatusFilter ? status : .any
        guard selectedGenre != normalizedGenre || selectedStatus != normalizedStatus else { return }

        searchTask?.cancel()
        selectedGenre = normalizedGenre
        selectedStatus = normalizedStatus
        mangas = [:]
        isLoading = false
        search()
    }

    private func resetFilters() {
        tempSelectedGenre = .all
        tempSelectedStatus = .any
        setFilters(genre: .all, status: .any)
    }

    private func search() {
        if isLoading
            || !plugin.supportsSearch(
                isAuthor: isAuthorSearch, genre: selectedGenre, status: selectedStatus)
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
                    query, page: page, genre: requestGenre, status: requestStatus,
                    isAuthor: isAuthorSearch)

                guard !Task.isCancelled, requestGenre == selectedGenre,
                    requestStatus == selectedStatus,
                    plugin.supportsSearch(
                        isAuthor: isAuthorSearch, genre: selectedGenre, status: selectedStatus)
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
