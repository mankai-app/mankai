//
//  DownloadModal.swift
//  mankai
//
//  Created by Travis XU on 14/2/2026.
//

import SwiftUI

struct DownloadModal: View {
    @ObservedObject var downloadService = DownloadService.shared
    @ObservedObject var downloadPlugin = DownloadPlugin.shared
    @Environment(\.dismiss) var dismiss

    let navigate: (Plugin, Manga) -> Void

    @State private var savedMangas: [DetailedManga] = []
    @State private var mangaToDelete: DetailedManga?
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if downloadService.sessionDownloads.isEmpty && savedMangas.isEmpty {
                    ContentUnavailableView(
                        "noActiveDownloads", systemImage: "arrow.down.circle",
                        description: Text("downloadQueueIsEmpty"))
                } else {
                    List {
                        if !downloadService.sessionDownloads.isEmpty {
                            Section("tasks") {
                                ForEach(downloadService.sessionDownloads) { download in
                                    DownloadMangaTaskRow(download: download)
                                }
                            }
                        }

                        if !savedMangas.isEmpty {
                            Section {
                                ForEach(savedMangas) { manga in
                                    DownloadedMangaRow(manga: manga, navigate: navigate)
                                }
                                .onDelete { offsets in
                                    guard let index = offsets.first,
                                        savedMangas.indices.contains(index)
                                    else { return }
                                    mangaToDelete = savedMangas[index]
                                    showDeleteConfirmation = true
                                }
                            } header: {
                                Text("savedDownloads")
                            } footer: {
                                Text("swipeToDelete")
                            }
                        }
                    }
                    .confirmationDialog(
                        "deleteManga", isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible, presenting: mangaToDelete
                    ) { manga in
                        Button("remove", role: .destructive) {
                            Task {
                                do { try await downloadService.deleteManga(manga) } catch {
                                    NotificationService.shared.showError(error.localizedDescription)
                                }
                            }
                        }
                        Button("cancel", role: .cancel) {}
                    } message: { _ in
                        Text("deleteMangaConfirmation")
                    }
                }
            }
            .navigationTitle("downloads").navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large]).presentationDragIndicator(.hidden)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("close") { dismiss() } }
            }
            .task {
                do { try await downloadService.start() } catch {
                    NotificationService.shared.showError(error.localizedDescription)
                }

                await loadSavedMangas()
            }
            .onReceive(downloadPlugin.objectWillChange) { _ in Task { await loadSavedMangas() } }
        }
    }

    func loadSavedMangas() async {
        do { savedMangas = try await downloadPlugin.getSavedMangas() } catch {
            Logger.ui.error("Failed to load downloaded mangas: \(error)")
        }
    }

}

struct DownloadedMangaRow: View {
    let manga: DetailedManga
    let navigate: (Plugin, Manga) -> Void

    @State private var showingExportModal = false

    private var downloadedChapterIds: Set<String> {
        Set(manga.chapters.flatMap(\.chapters).filter { $0.locked != true }.map(\.id))
    }

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 12) {
                MangaCoverView(coverUrl: manga.cover, plugin: DownloadPlugin.shared)
                    .aspectRatio(3 / 4, contentMode: .fit).frame(height: 100)

                VStack(alignment: .leading, spacing: 4) {
                    Text(manga.title ?? manga.id).font(.headline).lineLimit(1)

                    if let chapterCount = totalChapterCount {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "chapterCountFormat"), chapterCount)
                        )
                        .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("downloadNoCompletedChapters").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right").foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if manga.meta != nil, !downloadedChapterIds.isEmpty {
                Button("export", systemImage: "square.and.arrow.up") { showingExportModal = true }
            }
        }
        .sheet(isPresented: $showingExportModal) {
            if let pluginId = manga.meta {
                ExportModal(
                    manga: manga,
                    downloadMangaId: DownloadMangaModel.makeId(
                        pluginId: pluginId, mangaId: manga.id), chapterGroups: manga.chapters,
                    downloadedChapterIds: downloadedChapterIds, downloadedCoverUrl: manga.cover)
            }
        }
    }

    private func handleTap() {
        guard let pluginId = manga.meta, let plugin = PluginService.shared.getPlugin(pluginId)
        else { return }

        navigate(plugin, manga.toManga())
    }

    private var totalChapterCount: Int? {
        let count = downloadedChapterIds.count

        return count > 0 ? count : nil
    }
}

struct DownloadMangaTaskRow: View {
    @ObservedObject var download: MangaDownload

    @State private var showCancelConfirmation = false
    @State private var isExpanded = false

    private var status: DownloadState { download.status }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(download.orderedChapters) { task in
                DownloadChapterTaskRow(download: download, task: task)
            }
        } label: {
            HStack {
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(download.manga.title ?? download.manga.mangaId).font(.headline)
                        if status != .downloading {
                            Text(status.label).font(.caption)
                                .foregroundStyle(status == .failed ? Color.red : Color.secondary)
                        }

                        if status == .downloading {
                            Text(
                                String.localizedStringWithFormat(
                                    String(localized: "downloadChapterProgressFormat"),
                                    download.chapters.values.filter { $0.status == .completed }
                                        .count, download.chapters.count)
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if status == .failed {
                    Button {
                        perform {
                            for task in download.orderedChapters where task.status == .failed {
                                try await DownloadService.shared.retryChapter(
                                    mangaId: download.id, chapterId: task.chapter.chapterId)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill").font(.title2)
                            .frame(height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                } else if status == .paused {
                    Button {
                        perform { try await DownloadService.shared.resumeManga(id: download.id) }
                    } label: {
                        Image(systemName: "play.circle.fill").font(.title2).frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                } else if download.hasPendingChapters {
                    Button {
                        perform { try await DownloadService.shared.pauseManga(id: download.id) }
                    } label: {
                        Image(systemName: "pause.circle.fill").font(.title2).frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }

                if download.hasPendingChapters {
                    Button(role: .destructive) {
                        showCancelConfirmation = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.red)
                            .frame(height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.trailing, 8)
        }
        .disabled(download.isChanging)
        .confirmationDialog(
            "cancelDownload", isPresented: $showCancelConfirmation, titleVisibility: .visible
        ) {
            Button("yes", role: .destructive) {
                perform { try await DownloadService.shared.cancelManga(id: download.id) }
            }
            Button("no", role: .cancel) {}
        } message: {
            Text("cancelDownloadConfirmation")
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch {
                NotificationService.shared.showError(error.localizedDescription)
            }
        }
    }
}

struct DownloadChapterTaskRow: View {
    @ObservedObject var download: MangaDownload
    @ObservedObject var task: ChapterDownload

    private var status: DownloadState { download.state(for: task) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.chapter.title ?? task.chapter.chapterId).font(.subheadline).lineLimit(1)

                if status != .downloading {
                    Text(status.label).font(.caption)
                        .foregroundStyle(status == .failed ? Color.red : Color.secondary)
                }

                if status == .downloading, let total = task.totalImages {
                    ProgressView(value: task.progress)

                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "downloadPageProgressFormat"), task.completedImages,
                            total)
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }

                if status == .failed || status == .waitingForRetry, let error = task.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }

                if status == .waitingForRetry, let next = task.nextRetryAt {
                    Text(next, style: .timer).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if status == .failed {
                Button {
                    perform {
                        try await DownloadService.shared.retryChapter(
                            mangaId: download.id, chapterId: task.chapter.chapterId)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.title2)
                }
            }
        }
        .buttonStyle(.borderless).disabled(download.isChanging)

    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch {
                NotificationService.shared.showError(error.localizedDescription)
            }
        }
    }
}
