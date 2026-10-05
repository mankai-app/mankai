//
//  HomeTab.swift
//  mankai
//
//  Created by Travis XU on 20/6/2025.
//

import SwiftUI

private enum HomeMangaStatus: String, CaseIterable {
    case all
    case onGoing
    case completed
    case updated
    case unread
}

private enum HomeDataSource: String, CaseIterable {
    case collections
    case downloads
}

private struct HomeLibraryState {
    var mangas: [String: Manga] = [:]
    var plugins: [String: Plugin] = [:]
    var progressEntries: [String: ProgressModel] = [:]
    var libraryItems: [String: LibraryModel] = [:]
    var orders: [String] = []
    var filteredOrders: [String] = []
}

struct HomeTab: View {
    private let pluginService = PluginService.shared
    private let browseService = BrowseService.shared
    @ObservedObject private var syncService = SyncService.shared
    @ObservedObject private var updateService = UpdateService.shared

    @State private var library = HomeLibraryState()

    // Filter & Search
    @State private var searchText: String = ""
    @State private var showPlugins: [String] = []
    @State private var status: HomeMangaStatus = .all
    @State private var dataSource: HomeDataSource = .collections
    @State private var showingFilters = false
    @State private var showingDownloads = false

    /// Downloads state
    @State private var isLoadingDownloads = false

    /// Update state
    @State private var isRefreshing = false

    /// First initialization and connectivity check
    @State private var showNoInternetAlert = false

    // Navigation from download modal
    @State private var navigateToManga: Manga? = nil
    @State private var navigateToPlugin: Plugin? = nil
    @State private var navigateToDetails: Bool = false

    private var hasActiveFilters: Bool {
        if dataSource == .downloads { return false }

        let allPluginIds = Set(allPlugins.keys)
        let showSet = Set(showPlugins)
        return showSet != allPluginIds
    }

    private var isDownloadsMode: Bool { dataSource == .downloads }

    private var homeNavigationSubtitle: Text {
        if syncService.isSyncing { return Text("syncing") }

        if let progress = updateService.progress {
            guard progress.total > 0 else { return Text("updating") }
            let format = String(localized: "updatingProgressFormat")
            return Text(verbatim: String(format: format, progress.completed, progress.total))
        }

        let format = String(localized: "titleCountFormat")
        return Text(verbatim: String(format: format, library.filteredOrders.count))
    }

    private var allPlugins: [String: Plugin] {
        var pluginsById = Dictionary(
            uniqueKeysWithValues: pluginService.plugins.map { ($0.id, $0) })

        for plugin in browseService.plugins where pluginsById[plugin.id] == nil {
            pluginsById[plugin.id] = plugin
        }

        return pluginsById
    }

    private var availablePlugins: [Plugin] {
        return pluginService.plugins.sorted { plugin1, plugin2 in
            let name1 = plugin1.name ?? plugin1.id
            let name2 = plugin2.name ?? plugin2.id
            return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
        }
    }

    private var availableFolders: [BrowsablePlugin] {
        return browseService.plugins.sorted { plugin1, plugin2 in
            let name1 = plugin1.name ?? plugin1.id
            let name2 = plugin2.name ?? plugin2.id
            return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isDownloadsMode && library.orders.isEmpty {
                    ContentUnavailableView(
                        "noSavedManga", systemImage: "bookmark.slash",
                        description: Text("noSavedMangaDescription"))
                } else if isDownloadsMode && library.orders.isEmpty && isLoadingDownloads {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if library.filteredOrders.isEmpty {
                    ContentUnavailableView(
                        "noResultsFound", systemImage: "magnifyingglass",
                        description: Text("noResultsFoundDescription"))
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            MangasListView(
                                mangas: library.mangas, plugins: library.plugins,
                                keys: library.filteredOrders,
                                progressEntries: library.progressEntries,
                                libraryItems: library.libraryItems, showsUnreadTag: true,
                                allowUnsupportedDetailsNavigation: isDownloadsMode)
                        }
                        .padding()
                    }
                    .refreshable {
                        if isDownloadsMode {
                            await reloadDownloads()
                        } else {
                            await performUpdate()
                        }
                    }
                }
            }
            .navigationTitle("home").navigationSubtitleIfAvailable(homeNavigationSubtitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("source", selection: $dataSource) {
                            Text("collections").tag(HomeDataSource.collections)
                            Text("downloads").tag(HomeDataSource.downloads)
                        }

                        Picker("status", selection: $status) {
                            Text("all").tag(HomeMangaStatus.all)
                            Text("onGoing").tag(HomeMangaStatus.onGoing)
                            Text("mangaCompleted").tag(HomeMangaStatus.completed)
                            Text("updated").tag(HomeMangaStatus.updated)
                            Text("unread").tag(HomeMangaStatus.unread)
                        }
                        .disabled(isDownloadsMode)
                    } label: {
                        Text(
                            LocalizedStringKey(
                                isDownloadsMode || status == .all
                                    ? dataSource.rawValue : status.rawValue))
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: { showingDownloads = true }) {
                        ToolbarIcon(systemName: "arrow.down", legacySystemName: "arrow.down.circle")
                    }

                    FilterButton(hasActiveFilters: hasActiveFilters) { showingFilters = true }
                        .disabled(isDownloadsMode)
                }
            }
            .searchable(
                text: $searchText,
                prompt: isDownloadsMode
                    ? LocalizedStringKey("searchDownloadedManga")
                    : LocalizedStringKey("searchSavedManga")
            )
            .onChange(of: searchText) { filterManga() }.onChange(of: status) { filterManga() }
            .onChange(of: dataSource) {
                Task { if isDownloadsMode { await reloadDownloads() } else { updateLibrary() } }
            }
            .onAppear {
                initializeShowPlugins()

                if isDownloadsMode { Task { await reloadDownloads() } } else { updateLibrary() }
            }
            .onReceive(pluginService.objectWillChange) {
                initializeShowPlugins()
                if !isDownloadsMode { updateLibrary() }
            }
            .onReceive(browseService.objectWillChange) {
                initializeShowPlugins()
                if !isDownloadsMode { updateLibrary() }
            }
            .onReceive(LibraryService.shared.changes) { change in
                if !isDownloadsMode { applyLibraryChange(change) }
            }
            .onReceive(MangaSnapshotService.shared.changes) { change in
                if !isDownloadsMode { applySnapshotChange(change) }
            }
            .onReceive(ProgressService.shared.changes) { change in applyProgressChange(change) }
            .onReceive(
                NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            ) { _ in checkInternetAndPrompt() }
            .sheet(isPresented: $showingFilters) {
                HomeFilterModal(
                    isPresented: $showingFilters, showPlugins: $showPlugins,
                    availablePlugins: availablePlugins, availableFolders: availableFolders,
                    onReset: resetFilters, onApply: filterManga)
            }
            .sheet(isPresented: $showingDownloads) {
                DownloadModal { plugin, manga in
                    navigateToDetails = true
                    navigateToPlugin = plugin
                    navigateToManga = manga

                    showingDownloads = false
                }
            }
            .navigationDestination(isPresented: $navigateToDetails) {
                if let plugin = navigateToPlugin, let manga = navigateToManga {
                    MangaDetailsScreen(plugin: plugin, manga: manga)
                }
            }
            .alert("noInternetConnection", isPresented: $showNoInternetAlert) {
                Button("switch") { dataSource = .downloads }

                Button("cancel", role: .cancel) {}
            } message: {
                Text("noInternetConnectionMessage")
            }
        }
    }

    private func updateLibrary() {
        var next = HomeLibraryState()

        let libraryItems: [LibraryModel] = LibraryService.shared.getAll()
        for libraryItem in libraryItems {
            let key = "\(libraryItem.pluginId)+\(libraryItem.mangaId)"

            if let plugin = allPlugins[libraryItem.pluginId] { next.plugins[key] = plugin }

            if let manga = MangaSnapshotService.shared.get(
                mangaId: libraryItem.mangaId, pluginId: libraryItem.pluginId)
            {
                next.mangas[key] = manga
            }

            next.libraryItems[key] = libraryItem
        }

        let ids = next.libraryItems.values.map { (mangaId: $0.mangaId, pluginId: $0.pluginId) }
        for progress in ProgressService.shared.get(ids: ids) {
            let key = "\(progress.pluginId)+\(progress.mangaId)"
            if next.libraryItems[key] != nil { next.progressEntries[key] = progress }
        }

        sortLibrary(&next)
        library = next
    }

    private func applyLibraryChange(_ change: LibraryService.Change) {
        switch change { case .upserted(let changedLibraryItems, let snapshots):
            updateLibraryItems(changedLibraryItems, snapshots: snapshots)
            case .deleted(let mangaId, let pluginId):
                removeLibraryItem(mangaId: mangaId, pluginId: pluginId)
        }
    }

    private func updateLibraryItems(
        _ changedLibraryItems: [LibraryModel], snapshots: [MangaSnapshotService.Upsert]
    ) {
        guard !changedLibraryItems.isEmpty || !snapshots.isEmpty else { return }
        var next = library

        for snapshot in snapshots {
            let key = "\(snapshot.pluginId)+\(snapshot.manga.id)"
            next.mangas[key] = snapshot.manga
            next.plugins[key] = allPlugins[snapshot.pluginId]
        }

        let changedKeys = changedLibraryItems.map { libraryItem in
            let key = "\(libraryItem.pluginId)+\(libraryItem.mangaId)"

            next.libraryItems[key] = libraryItem
            next.plugins[key] = allPlugins[libraryItem.pluginId]
            if next.mangas[key] == nil {
                next.mangas[key] = MangaSnapshotService.shared.get(
                    mangaId: libraryItem.mangaId, pluginId: libraryItem.pluginId)
            }

            return key
        }

        let changedIds = changedLibraryItems.map { (mangaId: $0.mangaId, pluginId: $0.pluginId) }
        let changedProgressEntries = Dictionary(
            uniqueKeysWithValues: ProgressService.shared.get(ids: changedIds)
                .map { ("\($0.pluginId)+\($0.mangaId)", $0) })

        for key in changedKeys { next.progressEntries[key] = changedProgressEntries[key] }

        sortLibrary(&next)
        library = next
    }

    private func removeLibraryItem(mangaId: String, pluginId: String) {
        let key = "\(pluginId)+\(mangaId)"
        var next = library

        next.mangas[key] = nil
        next.plugins[key] = nil
        next.libraryItems[key] = nil
        next.progressEntries[key] = nil
        next.orders.removeAll { $0 == key }
        filterManga(&next)
        library = next
    }

    private func applySnapshotChange(_ change: MangaSnapshotService.Change) {
        var next = library

        switch change { case .upserted(let snapshots):
            for snapshot in snapshots {
                let key = "\(snapshot.pluginId)+\(snapshot.manga.id)"

                if next.libraryItems[key] == nil {
                    next.libraryItems[key] = LibraryService.shared.get(
                        mangaId: snapshot.manga.id, pluginId: snapshot.pluginId)
                }

                guard next.libraryItems[key] != nil else { continue }
                next.mangas[key] = snapshot.manga
                next.plugins[key] = allPlugins[snapshot.pluginId]
            }
            sortLibrary(&next)
            case .deleted(let mangaId, let pluginId):
                let key = "\(pluginId)+\(mangaId)"
                next.mangas[key] = nil
                next.orders.removeAll { $0 == key }
                filterManga(&next)
        }
        library = next
    }

    private func applyProgressChange(_ change: ProgressService.Change) {
        var next = library

        switch change { case .upserted(let changedProgressEntries):
            for progress in changedProgressEntries {
                let key = "\(progress.pluginId)+\(progress.mangaId)"
                guard next.orders.contains(key) || next.libraryItems[key] != nil else { continue }
                next.progressEntries[key] = progress

                if !isDownloadsMode {
                    next.libraryItems[key] = LibraryService.shared.get(
                        mangaId: progress.mangaId, pluginId: progress.pluginId)
                }
            }
            case .deleted(let ids):
                for id in ids { next.progressEntries["\(id.pluginId)+\(id.mangaId)"] = nil }
        }

        if isDownloadsMode { filterManga(&next) } else { sortLibrary(&next) }
        library = next
    }

    private func sortLibrary(_ state: inout HomeLibraryState) {
        let keys = state.mangas.keys

        let sortedKeys = keys.sorted { key1, key2 in
            let libraryDate1 = state.libraryItems[key1]?.datetime
            let progressDate1 = state.progressEntries[key1]?.datetime
            let libraryDate2 = state.libraryItems[key2]?.datetime
            let progressDate2 = state.progressEntries[key2]?.datetime

            let newerDate1 = [libraryDate1, progressDate1].compactMap { $0 }.max()
            let newerDate2 = [libraryDate2, progressDate2].compactMap { $0 }.max()

            switch (newerDate1, newerDate2) { case (let date1?, let date2?):
                if abs(date1.timeIntervalSince(date2)) < 1e-3 { return key1 < key2 }
                return date1 > date2
                case (nil, _): return false
                case (_, nil): return true
            }
        }

        state.orders = sortedKeys
        filterManga(&state)
    }

    private func filterManga(_ state: inout HomeLibraryState) {
        var filtered = state.orders

        // Filter by search text
        if !searchText.isEmpty {
            filtered = filtered.filter { key in
                state.mangas[key]?.title?.localizedCaseInsensitiveContains(searchText) ?? false
            }
        }

        if !isDownloadsMode {
            // Filter by shown plugins
            filtered = filtered.filter { key in
                let pluginId = key.split(separator: "+").first.map(String.init) ?? ""
                return showPlugins.contains(pluginId)
            }

            // Filter by status
            if status != .all {
                filtered = filtered.filter { key in
                    guard let manga = state.mangas[key], let libraryItem = state.libraryItems[key]
                    else { return false }

                    switch status { case .all: return true case .onGoing:
                        return manga.status == .onGoing
                        case .completed: return manga.status == .completed
                        case .updated: return libraryItem.updates
                        case .unread: return state.progressEntries[key] == nil
                    }
                }
            }
        }

        state.filteredOrders = filtered
    }

    private func filterManga() {
        var next = library
        filterManga(&next)
        library = next
    }

    private func setStatus(_ newStatus: HomeMangaStatus) {
        guard newStatus != status else { return }
        status = newStatus
        filterManga()
    }

    private func initializeShowPlugins() { showPlugins = Array(allPlugins.keys) }

    private func resetFilters() {
        showPlugins = Array(allPlugins.keys)
        status = .all
        filterManga()
    }

    private func performUpdate() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        try? await UpdateService.shared.update()

        isRefreshing = false
    }

    private func reloadDownloads() async {
        isLoadingDownloads = true
        defer { isLoadingDownloads = false }

        var next = HomeLibraryState()
        var downloadOrders: [String] = []

        if let downloadedMangas = try? await DownloadPlugin.shared.getDownloadedMangas() {
            for manga in downloadedMangas.compactMap({ $0.toManga() }) {
                if let pluginId = manga.meta {
                    let key = "\(pluginId)+\(manga.id)"

                    next.mangas[key] = manga
                    next.plugins[key] = allPlugins[pluginId] ?? DummyPlugin(pluginId)
                    downloadOrders.append(key)
                }
            }
        }

        next.orders = downloadOrders
        updateDownloadProgress(for: downloadOrders, state: &next)
        filterManga(&next)
        library = next
    }

    private func updateDownloadProgress(for keys: [String], state: inout HomeLibraryState) {
        guard !keys.isEmpty else { return }

        let ids = keys.compactMap { key -> (mangaId: String, pluginId: String)? in
            let parts = key.split(separator: "+", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (mangaId: parts[1], pluginId: parts[0])
        }

        let fetchedProgressEntries = ProgressService.shared.get(ids: ids)

        if keys == state.orders { state.progressEntries = [:] }

        for progress in fetchedProgressEntries {
            let key = "\(progress.pluginId)+\(progress.mangaId)"
            state.progressEntries[key] = progress
        }
    }

    private func checkInternetAndPrompt() {
        guard !isDownloadsMode else { return }

        let reachability = Reach()
        let status = reachability.connectionStatus()

        switch status { case .offline, .unknown: showNoInternetAlert = true default: break
        }
    }
}
