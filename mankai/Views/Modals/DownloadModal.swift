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

    @State private var downloadedMangas: [DetailedManga] = []
    @State private var mangaToDelete: DetailedManga?
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if activeTasks.isEmpty && downloadedMangas.isEmpty {
                    ContentUnavailableView(
                        "noActiveDownloads", systemImage: "arrow.down.circle",
                        description: Text("downloadQueueIsEmpty"))
                } else {
                    List {
                        if !activeTasks.isEmpty {
                            Section("tasks") {
                                ForEach(activeTasks) { task in DownloadTaskRow(task: task) }
                            }
                        }

                        if !downloadedMangas.isEmpty {
                            Section {
                                ForEach(downloadedMangas) { manga in
                                    DownloadedMangaRow(manga: manga, navigate: navigate)
                                }
                                .onDelete { offsets in
                                    guard let index = offsets.first,
                                        downloadedMangas.indices.contains(index)
                                    else { return }
                                    mangaToDelete = downloadedMangas[index]
                                    showDeleteConfirmation = true
                                }
                            } header: {
                                Text("downloaded")
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
                            Task { try? await downloadPlugin.deleteManga(manga) }
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
            .task { await loadDownloadedMangas() }
            .onReceive(downloadPlugin.objectWillChange) { _ in Task { await loadDownloadedMangas() }
            }
        }
    }

    var activeTasks: [DownloadTask] {
        downloadService.tasks.values
            .filter {
                if case .completed = $0.status { return false }
                return true
            }
            .sorted { ($0.manga.title ?? "") < ($1.manga.title ?? "") }
    }

    func loadDownloadedMangas() async {
        do { downloadedMangas = try await downloadPlugin.getDownloadedMangas() } catch {
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
                    manga: manga, downloadMangaId: "\(pluginId)+\(manga.id)",
                    chapterGroups: manga.chapters, downloadedChapterIds: downloadedChapterIds)
            }
        }
    }

    private func handleTap() {
        guard let pluginId = manga.meta, let plugin = PluginService.shared.getPlugin(pluginId)
        else { return }

        navigate(plugin, manga.toManga())
    }

    private var totalChapterCount: Int? {
        let count = manga.chapters.flatMap(\.chapters).count
        return count > 0 ? count : nil
    }
}

struct DownloadTaskRow: View {
    @ObservedObject var task: DownloadTask
    @State private var showCancelConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            MangaCoverView(
                coverUrl: task.manga.cover,
                plugin: PluginService.shared.getPlugin(task.manga.pluginId)
            )
            .aspectRatio(3 / 4, contentMode: .fit).frame(height: 100)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.manga.title ?? task.manga.id).font(.headline).lineLimit(1)

                switch task.status { case .queued:
                    Text("queued").font(.subheadline).foregroundStyle(.secondary)
                    case .downloading(let progress):
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: progress).progressViewStyle(.linear)

                            Text(
                                progress, format: .percent.scale(100).precision(.fractionLength(0))
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    case .completed: Text("completed").font(.subheadline).foregroundStyle(.green)
                    case .failed(let error):
                        VStack(alignment: .leading, spacing: 4) {
                            Text("failed").font(.subheadline).foregroundStyle(.red)

                            Text(error.localizedDescription).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                }
            }

            Spacer()

            // Action Buttons
            if case .failed = task.status {
                Button {
                    Task { try? await DownloadService.shared.retryTask(id: task.id) }
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.title)
                        .foregroundStyle(.primary)
                }
            } else if case .downloading = task.status {
                Button {
                    showCancelConfirmation = true
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title).foregroundStyle(.red)
                }
            } else if case .queued = task.status {
                Button {
                    showCancelConfirmation = true
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.gray)
                }
            }
        }
        .confirmationDialog(
            "cancelDownload", isPresented: $showCancelConfirmation, titleVisibility: .visible
        ) {
            Button("yes", role: .destructive) {
                Task { try? await DownloadService.shared.cancelTask(id: task.id) }
            }
            Button("no", role: .cancel) {}
        } message: {
            Text("cancelDownloadConfirmation")
        }
    }
}
