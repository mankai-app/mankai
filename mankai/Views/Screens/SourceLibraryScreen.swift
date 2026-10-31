//
//  SourceLibraryScreen.swift
//  mankai
//
//  Created by Travis XU on 27/6/2025.
//

import SwiftUI

/// A source filter selects either a predefined genre or an opaque source-provided name.
enum SourceGenreFilter: Hashable {
    case standard(Genre)
    case custom(String)

    var standardGenre: Genre {
        if case .standard(let genre) = self { return genre }
        return .all
    }

    var customGenre: String? {
        if case .custom(let genre) = self { return genre }
        return nil
    }

    var label: Text {
        switch self { case .standard(let genre): return Text(LocalizedStringKey(genre.rawValue))
            case .custom(let genre): return Text(verbatim: genre)
        }
    }

    var cacheKey: String {
        switch self { case .standard(let genre): return "standard:" + genre.rawValue
            case .custom(let genre): return "custom:" + genre
        }
    }
}

struct SourceLibraryScreen: View {
    let plugin: Plugin

    @State var selectedGenre: SourceGenreFilter = .standard(.all)
    @State private var selectedStatus: Status = .any
    @State private var showingFilters = false

    @State private var tempSelectedGenre: SourceGenreFilter = .standard(.all)
    @State private var tempSelectedStatus: Status = .any

    @State private var isLoading: Bool = false
    @State private var listLoadID = UUID()
    @State private var mangasList: [String: [UInt: [Manga]]] = [:]
    @State private var showErrorAlert: Bool = false
    @State private var errorMessage: String = ""

    @State private var searchQuery: String = ""
    @State private var searchSuggestions: [String] = []
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var navigateToSearch: Bool = false
    @State private var readerRoute: ReaderRoute?
    @State private var isUpdateMangaModalPresented = false

    private var supportsGenreFilter: Bool {
        plugin.supports(.list) && plugin.supports(.listByGenre)
    }

    private var supportsCustomGenreFilter: Bool {
        plugin.supports(.list) && plugin.supports(.listByCustomGenre)
    }

    private var supportsStatusFilter: Bool {
        plugin.supports(.list) && plugin.supports(.listByStatus)
    }

    private var hasActiveFilters: Bool {
        selectedGenre != .standard(.all) || selectedStatus != .any
    }

    init(plugin: Plugin, selectedGenre: SourceGenreFilter = .standard(.all)) {
        self.plugin = plugin
        let normalizedGenre =
            plugin.supportsList(
                genre: selectedGenre.standardGenre, customGenre: selectedGenre.customGenre)
            ? selectedGenre : .standard(.all)
        _selectedGenre = State(initialValue: normalizedGenre)
        _tempSelectedGenre = State(initialValue: normalizedGenre)
    }

    private var allMangas: [Manga] {
        let key = "\(selectedGenre.cacheKey)_\(selectedStatus.rawValue)"

        guard let mangas = mangasList[key] else { return [] }

        let sortedKeys = mangas.keys.sorted()
        return sortedKeys.flatMap { mangas[$0] ?? [] }
    }

    private var hasLoadedCurrentFilter: Bool {
        let key = "\(selectedGenre.cacheKey)_\(selectedStatus.rawValue)"
        return mangasList[key] != nil
    }

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
            .onChange(of: selectedGenre, initial: false) { _, _ in
                proxy.scrollTo("mangasList", anchor: .top)
            }
            .onChange(of: selectedStatus, initial: false) { _, _ in
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
                plugin: plugin, query: searchQuery, genre: selectedGenre, status: selectedStatus)
        }
        .sheet(isPresented: $showingFilters) {
            NavigationView {
                List {
                    Section {
                        if supportsGenreFilter || supportsCustomGenreFilter {
                            Picker("genre", selection: $tempSelectedGenre) {
                                Text("all").tag(SourceGenreFilter.standard(.all))
                                if supportsGenreFilter {
                                    ForEach(
                                        plugin.availableGenres.filter { $0 != .all }, id: \.self
                                    ) { genre in
                                        Text(LocalizedStringKey(genre.rawValue))
                                            .tag(SourceGenreFilter.standard(genre))
                                    }
                                }
                                if supportsCustomGenreFilter {
                                    ForEach(plugin.availableCustomGenres, id: \.self) { genre in
                                        Text(verbatim: genre).tag(SourceGenreFilter.custom(genre))
                                    }
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

            if supportsGenreFilter || supportsCustomGenreFilter || supportsStatusFilter {
                ToolbarItem(placement: .topBarTrailing) {
                    FilterButton(hasActiveFilters: hasActiveFilters) { showingFilters = true }
                }
            }
        }
        .navigationTitleWithSubtitle(
            title: Text(plugin.name ?? plugin.id), subtitle: Text("library")
        )
        .onAppear { loadList() }.onReceive(plugin.objectWillChange) { reloadList() }
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
        loadList()
    }

    private func loadList() {
        if isLoading
            || !plugin.supportsList(
                genre: selectedGenre.standardGenre, status: selectedStatus,
                customGenre: selectedGenre.customGenre)
        {
            return
        }

        let key = "\(selectedGenre.cacheKey)_\(selectedStatus.rawValue)"

        let maxPage = mangasList[key]?.keys.max() ?? 0

        // reach the end of the list
        if mangasList[key]?[maxPage]?.count == 0 { return }

        let page = maxPage + 1

        let loadID = listLoadID
        let genre = selectedGenre
        let status = selectedStatus

        isLoading = true
        Task {
            do {
                let result = try await plugin.getList(
                    page: page, genre: genre.standardGenre, status: status,
                    customGenre: genre.customGenre)
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

    private func setGenre(_ genre: SourceGenreFilter) {
        guard genre != selectedGenre else { return }

        selectedGenre = genre
        loadList()
    }

    private func setStatus(_ status: Status) {
        guard status != selectedStatus else { return }

        selectedStatus = status
        loadList()
    }

    private func setFilters(genre: SourceGenreFilter, status: Status) {
        let normalizedGenre =
            plugin.supportsList(genre: genre.standardGenre, customGenre: genre.customGenre)
            ? genre : .standard(.all)
        let normalizedStatus = supportsStatusFilter ? status : .any

        if selectedGenre != normalizedGenre || selectedStatus != normalizedStatus {
            listLoadID = UUID()
            isLoading = false
            selectedGenre = normalizedGenre
            selectedStatus = normalizedStatus
        }

        loadList()
    }

    private func resetFilters() {
        tempSelectedGenre = .standard(.all)
        tempSelectedStatus = .any
        setFilters(genre: .standard(.all), status: .any)
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
