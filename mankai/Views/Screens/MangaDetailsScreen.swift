//
//  MangaDetailsScreen.swift
//  mankai
//
//  Created by Travis XU on 29/6/2025.
//

import SwiftUI
import WrappingHStack

struct MangaDetailsScreen: View {
    @ObservedObject var plugin: Plugin
    let manga: Manga

    @State private var detailedManga: DetailedManga? = nil
    @State private var hasFinishedInitialLoad = false

    @State private var showingChaptersModal = false
    @State private var selectedChapterGroupIndex: Int? = nil
    @State private var isReversed = true

    @State private var readerRoute: ReaderRoute?

    @State private var isUpdateMangaModalPresented = false
    @State private var isUpdateChaptersModalPresented = false
    @State private var isSelectChaptersModalPresented = false
    @State private var isExportModalPresented = false
    @State private var openDownloadAfterExport = false

    @State private var selectedGenre: Genre? = nil
    @State private var showPluginLibraryScreen = false

    @State private var searchQuery: String? = nil
    @State private var showPluginSearchScreen = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var record: RecordModel? = nil
    @State private var saved: SavedModel? = nil

    /// Offline access
    private var downloadMangaId: String { return "\(plugin.id)+\(manga.id)" }

    @State private var downloadManga: DetailedManga?
    @State private var downloadedChapterIds: Set<String>?

    private var mangaData: DetailedManga? { return detailedManga ?? downloadManga }

    private var selectedChapterGroup: ChapterGroup? {
        guard let mangaData, let selectedChapterGroupIndex,
            mangaData.chapters.indices.contains(selectedChapterGroupIndex)
        else { return nil }

        return mangaData.chapters[selectedChapterGroupIndex]
    }

    private var hasReadableChapter: Bool {
        mangaData?.chapters.flatMap(\.chapters).contains(where: canRead) == true
    }

    private func canRead(_ chapter: Chapter) -> Bool {
        downloadedChapterIds?.contains(chapter.id) == true
            || (chapter.locked != true && plugin.supportsRemoteReading)
    }

    init(plugin: Plugin, manga: Manga) {
        self.plugin = plugin
        self.manga = manga
    }

    private func updateRecord() {
        record = HistoryService.shared.get(mangaId: manga.id, pluginId: plugin.id)
    }

    private func updateSaved() {
        saved = SavedService.shared.get(mangaId: manga.id, pluginId: plugin.id)
    }

    private func navigateToChapter(
        _ chapter: Chapter, page: Int? = nil, chapterGroupIndex: Int? = nil
    ) {
        guard let mangaData,
            let readerChapterGroupIndex = chapterGroupIndex ?? selectedChapterGroupIndex,
            canRead(chapter)
        else { return }

        showingChaptersModal = false
        readerRoute = ReaderRoute(
            plugin: plugin, manga: mangaData, downloadManga: downloadManga,
            chapterGroupIndex: readerChapterGroupIndex, chapter: chapter, initialPage: page)
    }

    private func scrollToRecord(proxy: ScrollViewProxy) {
        guard let record = record, let mangaData = mangaData else { return }

        guard
            let targetIndex = mangaData.chapters.firstIndex(where: { group in
                group.chapters.contains { $0.id == record.chapterId }
            })
        else { return }

        if selectedChapterGroupIndex == targetIndex {
            proxy.scrollTo(record.chapterId, anchor: .center)
        } else {
            selectedChapterGroupIndex = targetIndex
        }
    }

    private func handleReadContinueAction() {
        if let record = record, let mangaData = mangaData {
            for (groupIndex, group) in mangaData.chapters.enumerated() {
                if let chapter = group.chapters.first(where: {
                    $0.id == record.chapterId && canRead($0)
                }) {
                    navigateToChapter(chapter, page: record.page, chapterGroupIndex: groupIndex)
                    return
                }
            }
        }

        if let mangaData = mangaData {
            if let groupIndex = mangaData.chapters.firstIndex(where: {
                $0.chapters.contains(where: canRead)
            }), let chapter = mangaData.chapters[groupIndex].chapters.first(where: canRead) {
                navigateToChapter(chapter, chapterGroupIndex: groupIndex)
            }
        }
    }

    private func handleBookmarkAction() {
        Task {
            do {
                if saved != nil {
                    let _ = try await SavedService.shared.remove(
                        mangaId: manga.id, pluginId: plugin.id)
                } else {
                    let newSaved = SavedModel(
                        mangaId: manga.id, pluginId: plugin.id, datetime: Date(), updates: false,
                        latestChapter: manga.latestChapter?.encode() ?? "",
                        shouldSync: plugin.shouldSync)

                    let mangaModel = try MangaSnapshotService.shared.makeSnapshot(
                        for: manga, pluginId: plugin.id)

                    let _ = try await SavedService.shared.add(saved: newSaved, manga: mangaModel)
                }
            } catch { Logger.ui.error("Failed to delete or create SavedData") }
        }
    }

    var info: some View {
        List {
            if mangaData != nil && detailedManga == nil {
                Section {
                    Text("usingDownloadMangaDescription").foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } header: {
                    Spacer(minLength: 0)
                }
            }

            if let remarks = mangaData?.remarks, !remarks.isEmpty {
                Section("remarks") { Text(remarks) }
            }

            Section {
            } header: {
                VStack {
                    MangaCoverView(coverUrl: mangaData?.cover ?? manga.cover, plugin: plugin)
                        .aspectRatio(3 / 4, contentMode: .fit).padding(.horizontal)
                        .padding(.horizontal).frame(maxWidth: 400)

                    Text(mangaData?.title ?? manga.title ?? mangaData?.id ?? manga.id).font(.title2)
                        .fontWeight(.bold).multilineTextAlignment(.center).textSelection(.enabled)
                        .padding(.top, 12).foregroundColor(.primary)

                    if let authors = mangaData?.authors, !authors.isEmpty {
                        HStack(spacing: 4) {
                            HStack(spacing: 4) {
                                ForEach(authors, id: \.self) { author in
                                    if plugin.supportsSearch(isAuthor: true) {
                                        Button(action: {
                                            searchQuery = author
                                            showPluginSearchScreen = true
                                        }) { Text(author).foregroundStyle(.secondary) }
                                    } else {
                                        Text(author).foregroundStyle(.secondary)
                                    }
                                }
                            }

                            if plugin.supportsSearch(isAuthor: true) {
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.primary.opacity(0.7))
                            }
                        }
                        .font(.subheadline).foregroundColor(.secondary)
                    }
                }
                .textCase(.none).frame(maxWidth: .infinity)
            }
            .listRowInsets(EdgeInsets()).padding(.top)

            Section {
                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        if let updatedAt = mangaData?.updatedAt {
                            Text(updatedAt.formatted(date: .abbreviated, time: .omitted))
                            Text(verbatim: "•")
                        }

                        if let chapters = mangaData?.chapters {
                            Text(
                                String.localizedStringWithFormat(
                                    String(localized: "chapterCountFormat"),
                                    chapters.flatMap(\.chapters).count))
                        }

                        if let status = mangaData?.status {
                            Text(verbatim: "•")
                            Text(status.localizedName)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button(action: handleReadContinueAction) {
                            HStack {
                                Image(systemName: "book.pages.fill")
                                Text(record != nil ? "continue" : "read")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                        .disabled(!hasReadableChapter)

                        Button(action: handleBookmarkAction) {
                            HStack {
                                Image(
                                    systemName: saved != nil
                                        ? "bookmark.slash.fill" : "bookmark.fill")
                                Text(saved != nil ? "remove" : "bookmark")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(saved != nil ? nil : Color.accentColor)
                        .frame(maxWidth: .infinity)
                    }

                    if let record = record {
                        HStack(spacing: 4) {
                            HStack {
                                if !record.shouldSync {
                                    Image("custom.arrow.trianglehead.2.clockwise.rotate.90.slash")
                                        .foregroundStyle(.orange)
                                }

                                Text("lastRead")
                            }

                            if let chapterTitle = record.chapterTitle {
                                Text(verbatim: "•")
                                Text(chapterTitle).lineLimit(1)
                            } else {
                                Text(verbatim: "•")
                                Text(
                                    String(
                                        format: String(localized: "chapterFormat"), record.chapterId
                                    )
                                )
                                .lineLimit(1)
                            }

                            Text(verbatim: "•")
                            Text(
                                String(
                                    format: String(localized: "pageFormat"),
                                    (record.page + 1).description))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            } header: {
                Spacer(minLength: 0)
            }

            if let description = mangaData?.description {
                Section {
                    Text(description)
                } header: {
                    Text("description").padding(.top)
                }
            }

            if let genres = mangaData?.genres, !genres.isEmpty {
                Section {
                    WrappingHStack(genres, id: \.self, lineSpacing: 8) { genre in
                        if plugin.supportsList(genre: genre) {
                            Button(action: {
                                selectedGenre = genre
                                showPluginLibraryScreen = true
                            }) { Text(LocalizedStringKey(genre.rawValue)).genreTagStyle() }
                            .buttonStyle(.borderless)
                        } else {
                            Text(LocalizedStringKey(genre.rawValue)).genreTagStyle()
                        }
                    }
                    .padding().listRowInsets(EdgeInsets())
                } header: {
                    Text("genres").padding(.top)
                }
            }

            if let mangaData = mangaData, !mangaData.chapters.isEmpty {
                Section {
                    ForEach(Array(mangaData.chapters.enumerated()), id: \.offset) {
                        groupIndex, group in
                        Button(action: {
                            selectedChapterGroupIndex = groupIndex
                            showingChaptersModal = horizontalSizeClass == .compact
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(LocalizedStringKey(group.title))
                                            .foregroundColor(.primary)

                                        Text(
                                            String.localizedStringWithFormat(
                                                String(localized: "chapterCountFormat"),
                                                group.chapters.count)
                                        )
                                        .smallTagStyle()
                                    }

                                    if let latestChapter = group.chapters.last {
                                        HStack(spacing: 4) {
                                            Text("latest").font(.caption).foregroundColor(.primary)

                                            Text(latestChapter.title ?? latestChapter.id)
                                                .font(.caption).foregroundStyle(.secondary)
                                                .foregroundColor(.secondary).lineLimit(1)
                                        }
                                    }
                                }

                                Spacer()

                                Image(systemName: "list.bullet").foregroundColor(.secondary)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("chapters").padding(.top)
                }
            }
        }
    }

    private func chapterRow(_ chapter: Chapter) -> some View {
        let chapterTitle = chapter.title ?? chapter.id
        let isDownloaded = downloadedChapterIds?.contains(chapter.id) == true
        let isCurrentChapter = record?.chapterId == chapter.id
        let isAvailable = canRead(chapter)
        let chapterIcon = isAvailable ? "chevron.right" : "lock.fill"

        return Button(action: { navigateToChapter(chapter) }) {
            HStack {
                Text(chapterTitle).foregroundColor(.primary)

                if isDownloaded { Image(systemName: "network.slash").foregroundColor(.secondary) }

                if isCurrentChapter {
                    Image(systemName: "clock.arrow.circlepath").foregroundColor(.accentColor)
                }

                Spacer()
                Image(systemName: chapterIcon).foregroundColor(.secondary)
            }
        }
        .disabled(!isAvailable)
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                GeometryReader { geometry in
                    let infoWidth = max(400, geometry.size.width / 3)
                    let chaptersWidth = max(0, geometry.size.width - infoWidth)

                    HStack(spacing: 0) {
                        info.frame(minWidth: 400).frame(width: infoWidth)

                        if let selectedChapterGroup {
                            let chapters = selectedChapterGroup.chapters
                            let displayedChapters: [Chapter] =
                                isReversed ? Array(chapters.reversed()) : chapters
                            ScrollViewReader { proxy in
                                List {
                                    Section {
                                        if chapters.isEmpty {
                                            Text("noChaptersAvailable").foregroundStyle(.secondary)
                                        } else {
                                            ForEach(displayedChapters, id: \.id) { chapter in
                                                chapterRow(chapter)
                                            }
                                        }
                                    } header: {
                                        HStack {
                                            VStack(alignment: .leading) {
                                                Text(LocalizedStringKey(selectedChapterGroup.title))
                                                Text(
                                                    String.localizedStringWithFormat(
                                                        String(localized: "chapterCountFormat"),
                                                        chapters.count)
                                                )
                                                .font(.caption).foregroundStyle(.secondary)
                                            }

                                            Spacer()

                                            HStack {
                                                Button(action: { isReversed.toggle() }) {
                                                    Image(
                                                        systemName: isReversed
                                                            ? "arrow.up" : "arrow.down"
                                                    )
                                                    .font(.headline)
                                                }
                                                .buttonStyle(.plain)

                                                if plugin is Editable,
                                                    detailedManga?.editable ?? true
                                                {
                                                    Button(action: {
                                                        isUpdateChaptersModalPresented = true
                                                    }) {
                                                        Image(systemName: "pencil").font(.headline)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .onAppear { scrollToRecord(proxy: proxy) }
                                .onChange(of: record, initial: false) { _, _ in
                                    scrollToRecord(proxy: proxy)
                                }
                                .onChange(of: selectedChapterGroupIndex) {
                                    if let record = record {
                                        proxy.scrollTo(record.chapterId, anchor: .center)
                                    }
                                }
                            }
                            .frame(width: chaptersWidth)
                        } else {
                            ProgressView().frame(width: chaptersWidth).frame(maxHeight: .infinity)
                                .background(Color(.systemGroupedBackground))
                        }
                    }
                }
            } else {
                info
            }
        }
        .listSectionSpacing(0).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingChaptersModal) { [mangaData, selectedChapterGroupIndex] in
            if let mangaData = mangaData, let selectedChapterGroupIndex = selectedChapterGroupIndex
            {
                ChaptersModal(
                    plugin: plugin, manga: mangaData, chapterGroupIndex: selectedChapterGroupIndex,
                    record: record, downloadChapters: downloadedChapterIds,
                    canReadRemotely: plugin.supportsRemoteReading,
                    onNavigateToChapter: navigateToChapter)
            }
        }
        .sheet(isPresented: $isUpdateMangaModalPresented) { [detailedManga] in
            if let detailedManga = detailedManga, detailedManga.editable ?? true,
                let editablePlugin = plugin as? any Editable
            {
                UpdateMangaModal(plugin: editablePlugin, manga: detailedManga)
            }
        }
        .sheet(isPresented: $isUpdateChaptersModalPresented) {
            [detailedManga, selectedChapterGroupIndex] in
            if let detailedManga = detailedManga, detailedManga.editable ?? true,
                let selectedChapterGroupIndex = selectedChapterGroupIndex,
                let editablePlugin = plugin as? any Editable
            {
                UpdateChaptersModal(
                    plugin: editablePlugin, manga: detailedManga,
                    chapterGroupIndex: selectedChapterGroupIndex, isRootOfSheet: true)
            }
        }
        .sheet(isPresented: $isSelectChaptersModalPresented) { [detailedManga] in
            if let detailedManga = detailedManga {
                SelectChaptersModal(
                    plugin: plugin, detailedManga: detailedManga,
                    alreadyDownloaded: downloadedChapterIds,
                    downloadChapters: { chapters in
                        Task {
                            do {
                                _ = try await DownloadService.shared.queue(
                                    plugin: plugin, manga: detailedManga, chapters: chapters)
                            } catch { Logger.ui.error("Failed to queue download", error: error) }
                        }
                    })
            }
        }
        .sheet(
            isPresented: $isExportModalPresented,
            onDismiss: {
                if openDownloadAfterExport {
                    openDownloadAfterExport = false
                    isSelectChaptersModalPresented = true
                }
            }
        ) { [mangaData, downloadManga, downloadedChapterIds] in
            if let mangaData {
                ExportModal(
                    manga: mangaData, downloadMangaId: downloadMangaId,
                    chapterGroups: downloadManga?.chapters ?? mangaData.chapters,
                    downloadedChapterIds: downloadedChapterIds ?? [],
                    onDownload: plugin.supportsDownloads && detailedManga != nil
                        ? { openDownloadAfterExport = true } : nil)
            }
        }
        .navigationDestination(item: $readerRoute) { params in
            ReaderScreen(
                plugin: params.plugin, manga: params.manga, downloadManga: params.downloadManga,
                chapterGroupIndex: params.chapterGroupIndex, chapter: params.chapter,
                initialPage: params.initialPage)
        }
        .navigationDestination(isPresented: $showPluginLibraryScreen) {
            if let selectedGenre = selectedGenre {
                PluginLibraryScreen(plugin: plugin, selectedGenre: selectedGenre)
            }
        }
        .navigationDestination(isPresented: $showPluginSearchScreen) {
            if let searchQuery = searchQuery {
                PluginSearchScreen(plugin: plugin, query: searchQuery, isAuthorSearch: true)
            }
        }
        .toolbar {
            if plugin is Editable, detailedManga?.editable ?? true {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { isUpdateMangaModalPresented = true }) {
                        Label {
                            Text("editManga")
                        } icon: {
                            ToolbarIcon(systemName: "pencil", legacySystemName: "pencil.circle")
                        }
                    }
                    .labelStyle(.iconOnly).disabled(detailedManga == nil)
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if plugin.supportsDownloads, mangaData == nil || detailedManga != nil {
                    Button(action: { isSelectChaptersModalPresented = true }) {
                        Label {
                            Text("download")
                        } icon: {
                            ToolbarIcon(
                                systemName: "arrow.down", legacySystemName: "arrow.down.circle")
                        }
                    }
                    .disabled(detailedManga == nil)

                    Button(action: { isExportModalPresented = true }) {
                        Label("export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(mangaData == nil)
                }

                if let externalLink = mangaData?.externalLink,
                    let externalLinkURL = URL(string: externalLink)
                {
                    Link(destination: externalLinkURL) {
                        Label("openInBrowser", systemImage: "arrow.up.right.square")
                    }
                }
            } label: {
                Label {
                    Text("actions")
                } icon: {
                    ToolbarIcon(systemName: "ellipsis", legacySystemName: "ellipsis.circle")
                }
            }
        }
        .navigationTitleWithSubtitle(
            title: Text(mangaData?.title ?? manga.title ?? mangaData?.id ?? manga.id),
            subtitle: Text(plugin.name ?? plugin.id)
        )
        .onAppear {
            hasFinishedInitialLoad = false
            Task {
                var cachedError: Error?
                do { try await loadDetailedManga() } catch { cachedError = error }
                do { try await loadDownloadManga() } catch { cachedError = error }
                hasFinishedInitialLoad = true
                if let cachedError { handleMangaLoadError(cachedError) }
            }
            updateRecord()
            updateSaved()
        }
        .onReceive(plugin.objectWillChange) {
            Task { do { try await loadDetailedManga() } catch { handleMangaLoadError(error) } }
        }
        .onReceive(DownloadPlugin.shared.objectWillChange) {
            Task { do { try await loadDownloadManga() } catch { handleMangaLoadError(error) } }
        }
        .onReceive(SavedService.shared.objectWillChange) { updateSaved() }
        .onReceive(HistoryService.shared.objectWillChange) { updateRecord() }
        .toolbarBackground(
            horizontalSizeClass == .regular ? .visible : .automatic, for: .navigationBar)
    }

    private func loadDetailedManga() async throws {
        defer { updateSelectedChapterGroup() }

        guard plugin.supports(.mangaDetails) else {
            detailedManga = nil
            return
        }

        do { detailedManga = try await plugin.getDetailedManga(manga.id) } catch {
            detailedManga = nil

            // If the plugin is editable, there is a high chance that it is deleted
            if !(plugin is Editable) {
                Logger.ui.error("Failed to load detailed manga", error: error)
            }

            throw error
        }
    }

    private func loadDownloadManga() async throws {
        defer { updateSelectedChapterGroup() }

        do {
            let downloadedManga = try await DownloadPlugin.shared.getDetailedManga(downloadMangaId)
            downloadManga = downloadedManga
            downloadedChapterIds = Set(
                downloadedManga.chapters.flatMap { group in
                    group.chapters.filter { !($0.locked ?? false) }.map(\.id)
                })
        } catch {
            if detailedManga == nil {
                Logger.ui.error("Failed to load detailed manga", error: error)
            }

            throw error
        }
    }

    private func updateSelectedChapterGroup() {
        guard let mangaData, !mangaData.chapters.isEmpty else {
            selectedChapterGroupIndex = nil
            return
        }

        if let selectedChapterGroupIndex,
            mangaData.chapters.indices.contains(selectedChapterGroupIndex)
        {
            return
        }

        selectedChapterGroupIndex = 0
    }

    private func handleMangaLoadError(_ error: Error) {
        guard hasFinishedInitialLoad, mangaData == nil else { return }

        let message = String(localized: "failedToLoadMangaDetails")
        NotificationService.shared.showError(String(format: message, error.localizedDescription))

        dismiss()
    }
}
