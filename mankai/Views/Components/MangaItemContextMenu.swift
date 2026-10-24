//
//  MangaItemContextMenu.swift
//  mankai
//
//  Created by Travis XU on 24/10/2026.
//

import SwiftUI

struct MangaItemContextMenu: ViewModifier {
    let manga: Manga
    let plugin: Plugin
    let progress: ProgressModel?
    let libraryItem: LibraryModel?
    let allowUnsupportedDetailsNavigation: Bool
    let onRead: (ReaderRoute) -> Void

    private enum Sheet: String, Identifiable {
        case download, edit, share
        var id: String { rawValue }
    }

    private enum Action { case download, read, edit, delete, share }

    @State private var loadedProgress: ProgressModel?
    @State private var loadedLibraryItem: LibraryModel?
    @State private var detailedManga: DetailedManga?
    @State private var downloadManga: DetailedManga?
    @State private var sheet: Sheet?
    @State private var openDownloadAfterExport = false
    @State private var isProcessing = false
    @State private var showingDeleteConfirmation = false

    private var menuProgress: ProgressModel? { progress ?? loadedProgress }

    private var isBookmarked: Bool { (libraryItem ?? loadedLibraryItem) != nil }

    private var canEdit: Bool {
        plugin is any Editable && plugin.supports(.mangaDetails) && detailedManga?.editable != false
    }

    private var downloadedChapterIds: Set<String> {
        Set(
            downloadManga?.chapters.flatMap(\.chapters).filter { $0.locked != true }.map(\.id) ?? []
        )
    }

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                open(.read, readingProgress: menuProgress)
            } label: {
                Label(
                    menuProgress == nil ? "startReading" : "continueReading",
                    systemImage: "book.pages")
            }
            .disabled(
                isProcessing
                    || (!(plugin.supports(.mangaDetails) && plugin.supportsRemoteReading)
                        && !allowUnsupportedDetailsNavigation && downloadedChapterIds.isEmpty)
            )
            .onAppear(perform: loadMissingRecords)

            Button {
                toggleBookmark(isBookmarked: isBookmarked)
            } label: {
                Label(
                    isBookmarked ? "removeBookmark" : "bookmark",
                    systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
            }
            .disabled(isProcessing)

            Divider()

            Button("download", systemImage: "arrow.down") { open(.download) }
                .disabled(
                    !plugin.supportsDownloads || !plugin.supports(.mangaDetails) || isProcessing)

            Button("share", systemImage: "square.and.arrow.up") { open(.share) }
                .disabled(isProcessing)

            Button("edit", systemImage: "pencil") { open(.edit) }.disabled(!canEdit || isProcessing)

            Divider()

            if menuProgress != nil {
                Button("removeRecords", systemImage: "clock.badge.xmark", role: .destructive) {
                    perform {
                        _ = try await ProgressService.shared.remove(
                            mangaId: manga.id, pluginId: plugin.id)
                        loadedProgress = nil
                    }
                }
                .disabled(isProcessing)
            }

            Button("delete", systemImage: "trash", role: .destructive) { open(.delete) }
                .disabled(!canEdit || isProcessing)
        }
        .sheet(
            item: $sheet,
            onDismiss: {
                if openDownloadAfterExport {
                    openDownloadAfterExport = false
                    sheet = .download
                }
            }
        ) { sheet in
            switch sheet { case .download:
                if let detailedManga {
                    SelectChaptersModal(
                        plugin: plugin, detailedManga: detailedManga,
                        downloadChapters: { chapters in
                            perform {
                                try await DownloadService.shared.queue(
                                    plugin: plugin, manga: detailedManga, chapters: chapters)
                            }
                        })
                }
                case .edit:
                    if let detailedManga, let editablePlugin = plugin as? any Editable {
                        UpdateMangaModal(plugin: editablePlugin, manga: detailedManga)
                    }
                case .share:
                    if let mangaData = detailedManga ?? downloadManga {
                        ExportModal(
                            manga: mangaData,
                            downloadMangaId: DownloadMangaModel.makeId(
                                pluginId: plugin.id, mangaId: manga.id),
                            chapterGroups: downloadManga?.chapters ?? mangaData.chapters,
                            downloadedChapterIds: downloadedChapterIds,
                            onDownload: plugin.supportsDownloads && detailedManga != nil
                                ? { openDownloadAfterExport = true } : nil)
                    }
            }
        }
        .confirmationDialog(
            "deleteManga", isPresented: $showingDeleteConfirmation, titleVisibility: .visible
        ) {
            Button("delete", role: .destructive) {
                perform {
                    guard let editablePlugin = plugin as? any Editable else { return }
                    try await editablePlugin.deleteManga(manga.id)
                }
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("deleteMangaConfirmation")
        }
        .onReceive(plugin.objectWillChange) { detailedManga = nil }
    }

    private func loadMissingRecords() {
        loadedProgress =
            progress ?? ProgressService.shared.get(mangaId: manga.id, pluginId: plugin.id)
        loadedLibraryItem =
            libraryItem ?? LibraryService.shared.get(mangaId: manga.id, pluginId: plugin.id)
    }

    private func loadDownloadManga() async {
        let id = DownloadMangaModel.makeId(pluginId: plugin.id, mangaId: manga.id)
        downloadManga = try? await DownloadPlugin.shared.getDetailedManga(id)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isProcessing else { return }
        isProcessing = true
        Task {
            defer { isProcessing = false }
            do { try await action() } catch {
                Logger.ui.error("Failed to perform manga action", error: error)
                NotificationService.shared.showError(error.localizedDescription)
            }
        }
    }

    private func toggleBookmark(isBookmarked: Bool) {
        perform {
            if isBookmarked {
                _ = try await LibraryService.shared.remove(mangaId: manga.id, pluginId: plugin.id)
                loadedLibraryItem = nil
            } else {
                let snapshot = MangaSnapshotService.shared.makeSnapshot(
                    for: detailedManga?.toManga() ?? manga, pluginId: plugin.id)
                try await MangaSnapshotService.shared.upsert(snapshot)
                let newLibraryItem = LibraryModel(
                    mangaId: manga.id, pluginId: plugin.id, datetime: Date(), updates: false,
                    latestChapter: manga.latestChapter, shouldSync: plugin.supports(.sync))
                _ = try await LibraryService.shared.save(libraryItem: newLibraryItem)
                loadedLibraryItem = newLibraryItem
            }
        }
    }

    private func open(_ action: Action, readingProgress: ProgressModel? = nil) {
        perform {
            if action == .read || action == .share { await loadDownloadManga() }

            if plugin.supports(.mangaDetails) {
                do { detailedManga = try await plugin.getDetailedManga(manga.id) } catch {
                    guard (action == .share || action == .read) && downloadManga != nil else {
                        throw error
                    }
                    detailedManga = nil
                }
            }

            switch action { case .download:
                guard detailedManga != nil else { return }
                sheet = .download
                case .edit, .delete:
                    guard canEdit, detailedManga != nil else {
                        NotificationService.shared.showError(String(localized: "readOnly"))
                        return
                    }
                    if action == .edit { sheet = .edit } else { showingDeleteConfirmation = true }
                case .share:
                    guard detailedManga != nil || downloadManga != nil else {
                        throw MankaiErrorCode.pluginMangaNotFound.makeError()
                    }
                    sheet = .share
                case .read: startReading(progress: readingProgress)
            }
        }
    }

    private func startReading(progress: ProgressModel?) {
        guard let mangaData = detailedManga ?? downloadManga else { return }
        let downloadedIds = downloadedChapterIds
        let canRead: (Chapter) -> Bool = {
            downloadedIds.contains($0.id) || ($0.locked != true && plugin.supportsRemoteReading)
        }
        var target: (groupIndex: Int, chapter: Chapter, page: Int?)?

        for (index, group) in mangaData.chapters.enumerated() {
            if let progress,
                let chapter = group.chapters.first(where: {
                    $0.id == progress.chapterId && canRead($0)
                })
            {
                target = (index, chapter, progress.page)
                break
            }
            if target == nil, let chapter = group.chapters.first(where: canRead) {
                target = (index, chapter, nil)
            }
        }

        guard let target else {
            NotificationService.shared.showError(String(localized: "noChaptersAvailable"))
            return
        }

        onRead(
            ReaderRoute(
                plugin: plugin, manga: mangaData, downloadManga: downloadManga,
                usesDownloadedMetadata: detailedManga == nil, chapterGroupIndex: target.groupIndex,
                chapter: target.chapter, initialPage: target.page))
    }
}
