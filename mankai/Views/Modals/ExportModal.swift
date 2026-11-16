//
//  ExportModal.swift
//  mankai
//
//  Created by Travis XU on 3/10/2026.
//

import SwiftUI

struct ExportModal: View {
    let manga: DetailedManga
    let downloadMangaId: String
    let chapterGroups: ChapterGroups
    let downloadedChapterIds: Set<String>
    let downloadedCoverUrl: String?
    var onDownload: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openFilesDestination) private var openFilesDestination

    @State private var selectedChapterIds: Set<String> = []
    @State private var selectedExporter: Exporter = .mma
    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var exportURLs: [URL] = []
    @State private var exportTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var savedURLs: Set<URL> = []
    @State private var openExportsAfterDismiss = false
    @State private var errorMessage: String?
    @State private var showingError = false

    private var availableGroups: ChapterGroups {
        chapterGroups.compactMap { group in
            var group = group
            group.chapters = group.chapters.filter { downloadedChapterIds.contains($0.id) }
            return group.chapters.isEmpty ? nil : group
        }
    }

    private var selectedGroups: ChapterGroups {
        availableGroups.compactMap { group in
            var group = group
            group.chapters = group.chapters.filter { selectedChapterIds.contains($0.id) }
            return group.chapters.isEmpty ? nil : group
        }
    }

    private var chapterSelection: Binding<Set<ChapterSelection>> {
        Binding(
            get: {
                Set(
                    availableGroups.enumerated()
                        .flatMap { groupIndex, group in
                            group.chapters.filter { selectedChapterIds.contains($0.id) }
                                .map { ChapterSelection(groupIndex: groupIndex, chapterId: $0.id) }
                        })
            },
            set: { selection in
                // Deselect every occurrence when a chapter appears in multiple groups.
                let deselected = self.chapterSelection.wrappedValue.subtracting(selection)
                selectedChapterIds = Set(selection.map(\.chapterId))
                    .subtracting(deselected.map(\.chapterId))
            })
    }

    var body: some View {
        NavigationStack {
            Group {
                if isExporting || !exportURLs.isEmpty {
                    exportView
                } else if availableGroups.isEmpty {
                    noDownloadsView
                } else {
                    selectionView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitleWithSubtitle(
                title: Text("export"),
                subtitle: selectedChapterIds.isEmpty
                    ? nil
                    : Text(
                        String(
                            format: String(localized: "selectedChapterCountFormat"),
                            selectedChapterIds.count))
            )
            .toolbar {
                if !isExporting {
                    ToolbarItem(
                        placement: exportURLs.isEmpty ? .cancellationAction : .confirmationAction
                    ) { Button("close") { dismiss() } }
                    if exportURLs.isEmpty, !availableGroups.isEmpty {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("export") { startExport() }.disabled(selectedChapterIds.isEmpty)
                        }
                    }
                }
            }
            .alert(
                exportURLs.isEmpty ? Text("failedToExport") : Text("failedToSaveExport"),
                isPresented: $showingError
            ) {
                Button("ok", role: .cancel) {}
            } message: {
                if let errorMessage { Text(errorMessage) }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isExporting)
        .onDisappear {
            let exporting = exportTask
            let saving = saveTask
            let shouldOpenExports = openExportsAfterDismiss
            openExportsAfterDismiss = false
            exporting?.cancel()
            saving?.cancel()
            Task {
                await exporting?.value
                await saving?.value
                Exporter.clearTemporaryFiles()
                if shouldOpenExports {
                    let plugin = AppDirBrowsablePlugin.shared
                    openFilesDestination(.folder(shareID: plugin.id, entry: plugin.exportsEntity))
                }
            }
        }
    }

    private var noDownloadsView: some View {
        ContentUnavailableView {
            Label("noDownloadedChapters", systemImage: "arrow.down.circle")
        } description: {
            Text("exportDownloadedChaptersOnly")
        } actions: {
            if let onDownload {
                Button("download", systemImage: "arrow.down") {
                    onDownload()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectionView: some View {
        List {
            Section {
                Picker("exportFormat", selection: $selectedExporter) {
                    ForEach(Exporter.allCases) { exporter in Text(exporter.name).tag(exporter) }
                }
            } footer: {
                switch selectedExporter { case .mma: Text("exportMmaSingleFile") case .pdf:
                    Text("exportPdfOneFilePerChapter")
                }
            }

            ChapterSelector(
                groups: availableGroups, selection: chapterSelection,
                footer: Text("exportDownloadedChaptersOnly")
            ) { chapter in Text(chapter.title ?? chapter.id).foregroundColor(.primary) }
        }
    }

    private var exportView: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    MangaCoverView(coverUrl: downloadedCoverUrl, plugin: DownloadPlugin.shared)
                        .aspectRatio(3 / 4, contentMode: .fit).frame(height: 100)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(manga.title ?? manga.id).font(.headline).lineLimit(1)

                        if exportURLs.isEmpty {
                            Text("exporting").font(.subheadline).foregroundStyle(.secondary)
                            ProgressView(value: exportProgress)
                            Text(exportProgress, format: .percent.precision(.fractionLength(0)))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("exportCompleted").font(.subheadline).foregroundStyle(.green)
                        }
                    }
                }
            }

            if !exportURLs.isEmpty {
                Section("exportFiles") {
                    ForEach(Array(exportURLs.enumerated()), id: \.offset) { _, url in
                        Label(url.lastPathComponent, systemImage: "doc").font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("actions") {
                    ShareLink(items: exportURLs) {
                        Label("shareExport", systemImage: "square.and.arrow.up")
                    }

                    if savedURLs.count == exportURLs.count {
                        Label("savedToExports", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                    } else {
                        Button(action: saveExports) {
                            HStack {
                                Label("saveToExports", systemImage: "square.and.arrow.down")
                                if saveTask != nil {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(saveTask != nil)
                    }
                }
            }
        }
    }

    private func startExport() {
        guard !isExporting, !selectedGroups.isEmpty else { return }
        let exporter = selectedExporter
        let chapters = selectedGroups
        isExporting = true
        exportProgress = 0
        exportTask = Task { @MainActor in
            defer {
                isExporting = false
                exportTask = nil
            }
            do {
                let urls = try await exporter.export(
                    manga: manga, downloadMangaId: downloadMangaId, chapters: chapters
                ) { @MainActor value in exportProgress = value }
                try Task.checkCancellation()
                guard !urls.isEmpty else { throw MankaiErrorCode.exportNoFilesCreated.makeError() }
                exportURLs = urls
            } catch is CancellationError {
                // Each exporter handles cleanup of its unfinished files.
            } catch {
                Logger.ui.error("Failed to export manga", error: error)
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func saveExports() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor in
            defer { saveTask = nil }
            do {
                for url in exportURLs where !savedURLs.contains(url) {
                    try Task.checkCancellation()
                    try await AppDirBrowsablePlugin.shared.saveExport(from: url)
                    savedURLs.insert(url)
                }
                try Task.checkCancellation()
                openExportsAfterDismiss = true
                dismiss()
            } catch is CancellationError {
                // Files already saved remain in Exports.
            } catch {
                Logger.ui.error("Failed to save export", error: error)
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}
