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
    var records: [String: RecordModel] = [:]
    var saveds: [String: SavedModel] = [:]
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
        return Text(verbatim: String(format: format, library.orders.count))
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
                                keys: library.filteredOrders, records: library.records,
                                saveds: library.saveds, showsUnreadTag: true,
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
                Task { if isDownloadsMode { await reloadDownloads() } else { updateSaved() } }
            }
            .onAppear {
                initializeShowPlugins()

                if isDownloadsMode { Task { await reloadDownloads() } } else { updateSaved() }
            }
            .onReceive(pluginService.objectWillChange) {
                initializeShowPlugins()
                if !isDownloadsMode { updateSaved() }
            }
            .onReceive(browseService.objectWillChange) {
                initializeShowPlugins()
                if !isDownloadsMode { updateSaved() }
            }
            .onReceive(SavedService.shared.changes) { change in
                if !isDownloadsMode { applySavedChange(change) }
            }
            .onReceive(MangaSnapshotService.shared.changes) { change in
                if !isDownloadsMode { applySnapshotChange(change) }
            }
            .onReceive(HistoryService.shared.changes) { change in applyHistoryChange(change) }
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

    private func updateSaved() {
        var next = HomeLibraryState()

        let savedList: [SavedModel] = SavedService.shared.getAll()
        for saved in savedList {
            let key = "\(saved.pluginId)+\(saved.mangaId)"

            if let plugin = allPlugins[saved.pluginId] { next.plugins[key] = plugin }

            if let manga = MangaSnapshotService.shared.get(
                mangaId: saved.mangaId, pluginId: saved.pluginId)
            {
                next.mangas[key] = manga
            }

            next.saveds[key] = saved
        }

        let ids = next.saveds.values.map { (mangaId: $0.mangaId, pluginId: $0.pluginId) }
        for record in HistoryService.shared.get(ids: ids) {
            let key = "\(record.pluginId)+\(record.mangaId)"
            if next.saveds[key] != nil { next.records[key] = record }
        }

        sortSaved(&next)
        library = next
    }

    private func applySavedChange(_ change: SavedService.Change) {
        switch change { case .upserted(let changedSaveds, let snapshots):
            updateSavedItems(changedSaveds, snapshots: snapshots)
            case .deleted(let mangaId, let pluginId):
                removeSavedItem(mangaId: mangaId, pluginId: pluginId)
        }
    }

    private func updateSavedItems(
        _ changedSaveds: [SavedModel], snapshots: [MangaSnapshotService.Upsert]
    ) {
        guard !changedSaveds.isEmpty || !snapshots.isEmpty else { return }
        var next = library

        for snapshot in snapshots {
            let key = "\(snapshot.pluginId)+\(snapshot.manga.id)"
            next.mangas[key] = snapshot.manga
            next.plugins[key] = allPlugins[snapshot.pluginId]
        }

        let changedKeys = changedSaveds.map { saved in
            let key = "\(saved.pluginId)+\(saved.mangaId)"

            next.saveds[key] = saved
            next.plugins[key] = allPlugins[saved.pluginId]
            if next.mangas[key] == nil {
                next.mangas[key] = MangaSnapshotService.shared.get(
                    mangaId: saved.mangaId, pluginId: saved.pluginId)
            }

            return key
        }

        let changedIds = changedSaveds.map { (mangaId: $0.mangaId, pluginId: $0.pluginId) }
        let changedRecords = Dictionary(
            uniqueKeysWithValues: HistoryService.shared.get(ids: changedIds)
                .map { ("\($0.pluginId)+\($0.mangaId)", $0) })

        for key in changedKeys { next.records[key] = changedRecords[key] }

        sortSaved(&next)
        library = next
    }

    private func removeSavedItem(mangaId: String, pluginId: String) {
        let key = "\(pluginId)+\(mangaId)"
        var next = library

        next.mangas[key] = nil
        next.plugins[key] = nil
        next.saveds[key] = nil
        next.records[key] = nil
        next.orders.removeAll { $0 == key }
        filterManga(&next)
        library = next
    }

    private func applySnapshotChange(_ change: MangaSnapshotService.Change) {
        var next = library

        switch change { case .upserted(let snapshots):
            for snapshot in snapshots {
                let key = "\(snapshot.pluginId)+\(snapshot.manga.id)"

                if next.saveds[key] == nil {
                    next.saveds[key] = SavedService.shared.get(
                        mangaId: snapshot.manga.id, pluginId: snapshot.pluginId)
                }

                guard next.saveds[key] != nil else { continue }
                next.mangas[key] = snapshot.manga
                next.plugins[key] = allPlugins[snapshot.pluginId]
            }
            sortSaved(&next)
            case .deleted(let mangaId, let pluginId):
                let key = "\(pluginId)+\(mangaId)"
                next.mangas[key] = nil
                next.orders.removeAll { $0 == key }
                filterManga(&next)
        }
        library = next
    }

    private func applyHistoryChange(_ change: HistoryService.Change) {
        var next = library

        switch change { case .upserted(let changedRecords):
            for record in changedRecords {
                let key = "\(record.pluginId)+\(record.mangaId)"
                guard next.orders.contains(key) || next.saveds[key] != nil else { continue }
                next.records[key] = record

                if !isDownloadsMode {
                    next.saveds[key] = SavedService.shared.get(
                        mangaId: record.mangaId, pluginId: record.pluginId)
                }
            }
        }

        if isDownloadsMode { filterManga(&next) } else { sortSaved(&next) }
        library = next
    }

    private func sortSaved(_ state: inout HomeLibraryState) {
        let keys = state.mangas.keys

        let sortedKeys = keys.sorted { key1, key2 in
            let savedDate1 = state.saveds[key1]?.datetime
            let recordDate1 = state.records[key1]?.datetime
            let savedDate2 = state.saveds[key2]?.datetime
            let recordDate2 = state.records[key2]?.datetime

            let newerDate1 = [savedDate1, recordDate1].compactMap { $0 }.max()
            let newerDate2 = [savedDate2, recordDate2].compactMap { $0 }.max()

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
                    guard let manga = state.mangas[key], let saved = state.saveds[key] else {
                        return false
                    }

                    switch status { case .all: return true case .onGoing:
                        return manga.status == .onGoing
                        case .completed: return manga.status == .completed
                        case .updated: return saved.updates
                        case .unread: return state.records[key] == nil
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
        updateDownloadRecords(for: downloadOrders, state: &next)
        filterManga(&next)
        library = next
    }

    private func updateDownloadRecords(for keys: [String], state: inout HomeLibraryState) {
        guard !keys.isEmpty else { return }

        let ids = keys.compactMap { key -> (mangaId: String, pluginId: String)? in
            let parts = key.split(separator: "+", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (mangaId: parts[1], pluginId: parts[0])
        }

        let fetchedRecords = HistoryService.shared.get(ids: ids)

        if keys == state.orders { state.records = [:] }

        for record in fetchedRecords {
            let key = "\(record.pluginId)+\(record.mangaId)"
            state.records[key] = record
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
