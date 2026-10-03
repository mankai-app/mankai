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
    var onDownload: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var selectedChapterIds: Set<String> = []
    @State private var expandedGroupIndex: Int? = nil
    @State private var selectedExporter: Exporter = .mma
    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var exportURLs: [URL] = []
    @State private var exportTask: Task<Void, Never>?
    @State private var exportError: String?
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
            .alert("failedToExport", isPresented: $showingError) {
                Button("ok", role: .cancel) {}
            } message: {
                if let exportError { Text(exportError) }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isExporting)
        .onDisappear {
            let task = exportTask
            task?.cancel()
            Task {
                if let task { await task.value }
                Exporter.clearTemporaryFiles()
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
                Text("exportDownloadedChaptersOnly")
            }

            ForEach(Array(availableGroups.enumerated()), id: \.offset) { index, group in
                Section {
                    chapterGroupRow(group, index: index)

                    if expandedGroupIndex == index {
                        ForEach(group.chapters, id: \.id) { chapter in chapterRow(chapter) }
                    }
                }
            }
        }
    }

    private func chapterGroupRow(_ group: ChapterGroup, index: Int) -> some View {
        let chapterIds = Set(group.chapters.map(\.id))
        let selectedCount = chapterIds.intersection(selectedChapterIds).count
        let allSelected = chapterIds.isSubset(of: selectedChapterIds)

        return HStack(spacing: 12) {
            Button {
                if allSelected {
                    selectedChapterIds.subtract(chapterIds)
                } else {
                    selectedChapterIds.formUnion(chapterIds)
                }
            } label: {
                Image(
                    systemName: allSelected
                        ? "checkmark.circle.fill"
                        : selectedCount > 0 ? "minus.circle.fill" : "circle"
                )
                .resizable().frame(width: 20, height: 20)
                .foregroundColor(selectedCount > 0 ? .accentColor : .secondary.opacity(0.5))
            }
            .buttonStyle(.plain)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey(group.title)).foregroundColor(.primary)

                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "chapterCountFormat"), group.chapters.count)
                        )
                        .smallTagStyle()
                    }

                    Text(
                        String(
                            format: String(localized: "selectedChapterCountFormat"), selectedCount)
                    )
                    .font(.caption).foregroundColor(.accentColor)
                }

                Spacer()

                Image(systemName: "chevron.right").font(.footnote).foregroundColor(.secondary)
                    .rotationEffect(.degrees(expandedGroupIndex == index ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation { expandedGroupIndex = expandedGroupIndex == index ? nil : index }
            }
        }
        .padding(.trailing, 4)
    }

    private func chapterRow(_ chapter: Chapter) -> some View {
        let selected = selectedChapterIds.contains(chapter.id)

        return Button {
            if selected {
                selectedChapterIds.remove(chapter.id)
            } else {
                selectedChapterIds.insert(chapter.id)
            }
        } label: {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
                Text(chapter.title ?? chapter.id).foregroundColor(.primary)
                Spacer()
            }
        }
    }

    private var exportView: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    MangaCoverView(coverUrl: manga.cover, plugin: DownloadPlugin.shared)
                        .aspectRatio(3 / 4, contentMode: .fit).frame(height: 100)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(manga.title ?? manga.id).font(.headline).lineLimit(1)

                        if exportURLs.isEmpty {
                            Text("exporting").font(.subheadline).foregroundStyle(.secondary)
                            ProgressView(value: exportProgress).progressViewStyle(.linear)
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

                    ShareLink(items: exportURLs) {
                        Label("shareExport", systemImage: "square.and.arrow.up")
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
                exportError = error.localizedDescription
                showingError = true
            }
        }
    }
}
