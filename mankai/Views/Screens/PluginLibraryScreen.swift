//
//  PluginLibraryScreen.swift
//  mankai
//
//  Created by Travis XU on 27/6/2025.
//

import SwiftUI

struct PluginLibraryScreen: View {
    let plugin: Plugin

    @State var selectedGenre: Genre = .all
    @State private var selectedStatus: Status = .any
    @State private var showingFilters = false

    @State private var tempSelectedGenre: Genre = .all
    @State private var tempSelectedStatus: Status = .any

    @State private var isLoading: Bool = false
    @State private var mangasList: [String: [UInt: [Manga]]] = [:]
    @State private var showErrorAlert: Bool = false
    @State private var errorMessage: String = ""

    @State private var searchQuery: String = ""
    @State private var searchSuggestions: [String] = []
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var navigateToSearch: Bool = false

    private var supportsGenreFilter: Bool {
        plugin.supports(.list) && plugin.supports(.listByGenre)
    }

    private var supportsStatusFilter: Bool {
        plugin.supports(.list) && plugin.supports(.listByStatus)
    }

    private var hasActiveFilters: Bool { selectedGenre != .all || selectedStatus != .any }

    init(plugin: Plugin, selectedGenre: Genre = .all) {
        self.plugin = plugin
        let normalizedGenre =
            plugin.supports(.list) && plugin.supports(.listByGenre) ? selectedGenre : .all
        _selectedGenre = State(initialValue: normalizedGenre)
        _tempSelectedGenre = State(initialValue: normalizedGenre)
    }

    private var allMangas: [Manga] {
        let key = "\(selectedGenre.rawValue)_\(selectedStatus.rawValue)"

        guard let mangas = mangasList[key] else { return [] }

        let sortedKeys = mangas.keys.sorted()
        return sortedKeys.flatMap { mangas[$0] ?? [] }
    }

    private var hasLoadedCurrentFilter: Bool {
        let key = "\(selectedGenre.rawValue)_\(selectedStatus.rawValue)"
        return mangasList[key] != nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack {
                    MangasListView(mangas: allMangas, plugin: plugin).id("mangasList")

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
            .onChange(of: selectedGenre, initial: false) { _, _ in
                proxy.scrollTo("mangasList", anchor: .top)
            }
            .onChange(of: selectedStatus, initial: false) { _, _ in
                proxy.scrollTo("mangasList", anchor: .top)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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
            PluginSearchScreen(
                plugin: plugin, query: searchQuery, genre: selectedGenre, status: selectedStatus)
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
        .toolbar {
            if supportsGenreFilter || supportsStatusFilter {
                ToolbarItem(placement: .primaryAction) {
                    FilterButton(hasActiveFilters: hasActiveFilters) { showingFilters = true }
                }
            }
        }
        .navigationTitleWithSubtitle(
            title: Text(plugin.name ?? plugin.id), subtitle: Text("library")
        )
        .onAppear { loadList() }
        .alert("failedToLoadList", isPresented: $showErrorAlert) {
            Button("ok") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func loadList() {
        if isLoading || !plugin.supportsList(genre: selectedGenre, status: selectedStatus) {
            return
        }

        let key = "\(selectedGenre.rawValue)_\(selectedStatus.rawValue)"

        let maxPage = mangasList[key]?.keys.max() ?? 0

        // reach the end of the list
        if mangasList[key]?[maxPage]?.count == 0 { return }

        let page = maxPage + 1

        isLoading = true
        Task {
            do {
                let result = try await plugin.getList(
                    page: page, genre: selectedGenre, status: selectedStatus)

                if mangasList[key] == nil { mangasList[key] = [:] }

                mangasList[key]![page] = result

                isLoading = false
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    private func setGenre(_ genre: Genre) {
        guard genre != selectedGenre else { return }

        selectedGenre = genre
        loadList()
    }

    private func setStatus(_ status: Status) {
        guard status != selectedStatus else { return }

        selectedStatus = status
        loadList()
    }

    private func setFilters(genre: Genre, status: Status) {
        let normalizedGenre = supportsGenreFilter ? genre : .all
        let normalizedStatus = supportsStatusFilter ? status : .any

        if selectedGenre != normalizedGenre { selectedGenre = normalizedGenre }

        if selectedStatus != normalizedStatus { selectedStatus = normalizedStatus }

        loadList()
    }

    private func resetFilters() {
        tempSelectedGenre = .all
        tempSelectedStatus = .any
        setFilters(genre: .all, status: .any)
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
