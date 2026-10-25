//
//  MangaItemContextMenu.swift
//  mankai
//
//  Created by Travis XU on 24/10/2026.
//

import SwiftUI

struct MangaItemContextMenu: ViewModifier {
    struct FileActions {
        let isSelecting: Bool
        let isBusy: Bool
        let download: () -> Void
        let select: () -> Void
        let delete: (() async throws -> Void)?
    }

    let manga: Manga?
    let plugin: Plugin
    let onRead: (ReaderRoute) -> Void
    var fileActions: FileActions? = nil

    private enum Sheet: String, Identifiable {
        case download, edit, share
        var id: String { rawValue }
    }

    private enum Action { case download, read, edit, delete, share }

    private struct RecordKey: Equatable {
        let pluginId: String
        let mangaId: String?

        func matches(mangaId: String, pluginId: String) -> Bool {
            self.mangaId == mangaId && self.pluginId == pluginId
        }
    }

    private struct Records {
        let key: RecordKey
        var progress: ProgressModel?
        var libraryItem: LibraryModel?
    }

    @State private var loadedRecords: Records?
    @State private var detailedManga: DetailedManga?
    @State private var downloadManga: DetailedManga?
    @State private var sheet: Sheet?
    @State private var openDownloadAfterExport = false
    @State private var isProcessing = false
    @State private var showingDeleteConfirmation = false

    private var recordKey: RecordKey { RecordKey(pluginId: plugin.id, mangaId: manga?.id) }

    private var records: Records {
        if let loadedRecords, loadedRecords.key == recordKey { return loadedRecords }
        return Records(key: recordKey, progress: nil, libraryItem: nil)
    }

    private var menuProgress: ProgressModel? { records.progress }

    private var isBookmarked: Bool { records.libraryItem != nil }

    private var isBusy: Bool { isProcessing || fileActions?.isBusy == true }

    // Only plugin capabilities control visibility. Item data and state control interaction.
    private var supportsDownload: Bool { plugin is any Browsable || plugin.supportsDownloads }

    private var supportsShare: Bool { !(plugin is any Browsable) }

    private var supportsEdit: Bool { !(plugin is any Browsable) && plugin is any Editable }

    private var supportsDelete: Bool { plugin is any FileDeletable || supportsEdit }

    private var canRead: Bool {
        manga != nil
            && ((plugin.supports(.mangaDetails) && plugin.supportsRemoteReading)
                || !downloadedChapterIds.isEmpty)
    }

    private var canDownload: Bool {
        fileActions != nil
            || (manga != nil && plugin.supportsDownloads && plugin.supports(.mangaDetails))
    }

    private var canShare: Bool {
        manga != nil && supportsShare && (plugin.supports(.mangaDetails) || downloadManga != nil)
    }

    private var canEdit: Bool {
        manga != nil && supportsEdit && plugin.supports(.mangaDetails)
            && detailedManga?.editable != false
    }

    private var canDelete: Bool { fileActions?.delete != nil || canEdit }

    private var needsDownloadMetadata: Bool {
        !plugin.supports(.mangaDetails) || !plugin.supportsRemoteReading
    }

    private var downloadedChapterIds: Set<String> {
        Set(
            downloadManga?.chapters.flatMap(\.chapters).filter { $0.locked != true }.map(\.id) ?? []
        )
    }

    func body(content: Content) -> some View {
        content.contextMenu {
            Group {
                Section {
                    Button {
                        open(.read)
                    } label: {
                        Label(
                            menuProgress == nil ? "startReading" : "continueReading",
                            systemImage: "book.pages")
                    }
                    .disabled(!canRead)

                    Button {
                        toggleBookmark()
                    } label: {
                        Label(
                            isBookmarked ? "removeBookmark" : "bookmark",
                            systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
                    }
                    .disabled(manga == nil)
                }

                Section {
                    if supportsDownload {
                        Button("download", systemImage: "arrow.down") { open(.download) }
                            .disabled(!canDownload)
                    }

                    if supportsShare {
                        Button("share", systemImage: "square.and.arrow.up") { open(.share) }
                            .disabled(!canShare)
                    }

                    if supportsEdit {
                        Button("edit", systemImage: "pencil") { open(.edit) }.disabled(!canEdit)
                    }

                    if plugin is any Browsable {
                        Button {
                            fileActions?.select()
                        } label: {
                            Label(
                                fileActions?.isSelecting == true ? "done" : "select",
                                systemImage: "checkmark.circle")
                        }
                        .disabled(fileActions == nil)
                    }
                }

                Section {
                    Button("removeRecords", systemImage: "clock.badge.xmark", role: .destructive) {
                        guard let manga else { return }
                        perform {
                            _ = try await ProgressService.shared.remove(
                                mangaId: manga.id, pluginId: plugin.id)
                            if loadedRecords?.key == recordKey { refreshRecords() }
                        }
                    }
                    .disabled(manga == nil || menuProgress == nil)

                    if supportsDelete {
                        Button("delete", systemImage: "trash", role: .destructive) { open(.delete) }
                            .disabled(!canDelete)
                    }
                }
            }
            .disabled(isBusy)
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
                    if let manga, let mangaData = detailedManga ?? downloadManga {
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
                    if let deleteFile = fileActions?.delete {
                        try await deleteFile()
                    } else if let manga, let editablePlugin = plugin as? any Editable {
                        try await editablePlugin.deleteManga(manga.id)
                    }
                }
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("deleteMangaConfirmation")
        }
        .onReceive(plugin.objectWillChange) { detailedManga = nil }
        .onAppear(perform: refreshRecords)
        .onChange(of: recordKey) {
            detailedManga = nil
            downloadManga = nil
            refreshRecords()
        }
        .onReceive(ProgressService.shared.changes, perform: updateProgress)
        .onReceive(LibraryService.shared.changes, perform: updateLibraryItem)
        .task(id: recordKey) { if needsDownloadMetadata { await loadDownloadManga() } }
        .onReceive(DownloadPlugin.shared.objectWillChange) {
            if needsDownloadMetadata { Task { await loadDownloadManga() } }
        }
    }

    private func refreshRecords() {
        guard let manga else {
            loadedRecords = Records(key: recordKey, progress: nil, libraryItem: nil)
            return
        }
        loadedRecords = Records(
            key: recordKey,
            progress: ProgressService.shared.get(mangaId: manga.id, pluginId: plugin.id),
            libraryItem: LibraryService.shared.get(mangaId: manga.id, pluginId: plugin.id))
    }

    private func updateProgress(_ change: ProgressService.Change) {
        var updated = records
        switch change { case .upserted(let entries):
            guard
                let entry = entries.first(where: {
                    recordKey.matches(mangaId: $0.mangaId, pluginId: $0.pluginId)
                })
            else { return }
            updated.progress = entry
            case .deleted(let keys):
                guard
                    keys.contains(where: {
                        recordKey.matches(mangaId: $0.mangaId, pluginId: $0.pluginId)
                    })
                else { return }
                updated.progress = nil
        }
        loadedRecords = updated
    }

    private func updateLibraryItem(_ change: LibraryService.Change) {
        var updated = records
        switch change { case .upserted(let entries):
            guard
                let entry = entries.first(where: {
                    recordKey.matches(mangaId: $0.mangaId, pluginId: $0.pluginId)
                })
            else { return }
            updated.libraryItem = entry
            case .deleted(let mangaId, let pluginId):
                guard recordKey.matches(mangaId: mangaId, pluginId: pluginId) else { return }
                updated.libraryItem = nil
        }
        loadedRecords = updated
    }

    private func loadDownloadManga() async {
        guard let manga else { return }
        let key = recordKey
        let id = DownloadMangaModel.makeId(pluginId: plugin.id, mangaId: manga.id)
        let downloaded = try? await DownloadPlugin.shared.getDetailedManga(id)
        guard !Task.isCancelled, loadedRecords?.key == key else { return }
        downloadManga = downloaded
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isProcessing = true
        Task {
            defer { isProcessing = false }
            do { try await action() } catch {
                Logger.ui.error("Failed to perform manga action", error: error)
                NotificationService.shared.showError(error.localizedDescription)
            }
        }
    }

    private func toggleBookmark() {
        guard let manga else { return }
        perform {
            if LibraryService.shared.get(mangaId: manga.id, pluginId: plugin.id) != nil {
                _ = try await LibraryService.shared.remove(mangaId: manga.id, pluginId: plugin.id)
            } else {
                let snapshot = MangaSnapshotService.shared.makeSnapshot(
                    for: detailedManga?.toManga() ?? manga, pluginId: plugin.id)
                try await MangaSnapshotService.shared.upsert(snapshot)
                let newLibraryItem = LibraryModel(
                    mangaId: manga.id, pluginId: plugin.id, datetime: Date(), updates: false,
                    latestChapter: manga.latestChapter, shouldSync: plugin.supports(.sync))
                _ = try await LibraryService.shared.save(libraryItem: newLibraryItem)
            }
            if loadedRecords?.key == recordKey { refreshRecords() }
        }
    }

    private func open(_ action: Action) {
        guard !isBusy else { return }
        if action == .download, let fileActions {
            fileActions.download()
            return
        }
        if action == .delete, fileActions?.delete != nil {
            showingDeleteConfirmation = true
            return
        }
        guard let manga else { return }
        let key = recordKey
        perform {
            if action == .read || action == .share { await loadDownloadManga() }
            guard loadedRecords?.key == key else { return }

            if plugin.supports(.mangaDetails) {
                do {
                    let detailed = try await plugin.getDetailedManga(manga.id)
                    guard loadedRecords?.key == key else { return }
                    detailedManga = detailed
                } catch {
                    guard loadedRecords?.key == key else { return }
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
                case .read:
                    startReading(
                        progress: ProgressService.shared.get(mangaId: manga.id, pluginId: plugin.id)
                    )
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
