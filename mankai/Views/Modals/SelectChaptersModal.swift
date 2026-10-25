//
//  SelectChaptersModal.swift
//  mankai
//
//  Created by Travis XU on 14/2/2026.
//

import SwiftUI

struct SelectChaptersModal: View {
    @Environment(\.dismiss) var dismiss
    let plugin: Plugin
    let detailedManga: DetailedManga

    @ObservedObject private var downloadService = DownloadService.shared

    let downloadChapters: (ChapterGroups) -> Void

    // Chapter-group index -> set of selected chapter IDs.
    @State private var selectedChapters: [Int: Set<String>] = [:]

    private var totalSelectedCount: Int { buildDownloadPayload().flatMap(\.chapters).count }

    private var chapterSelection: Binding<Set<ChapterSelection>> {
        Binding(
            get: {
                Set(
                    selectedChapters.flatMap { groupIndex, chapterIds in
                        chapterIds.map { ChapterSelection(groupIndex: groupIndex, chapterId: $0) }
                    })
            },
            set: { selection in
                var chapters: [Int: Set<String>] = [:]
                for item in selection {
                    chapters[item.groupIndex, default: []].insert(item.chapterId)
                }
                selectedChapters = chapters
            })
    }

    private func state(chapterId: String) -> DownloadState? {
        downloadService.chapterState(
            pluginId: plugin.id, mangaId: detailedManga.id, chapterId: chapterId)
    }

    private func isSelectable(_ chapter: Chapter) -> Bool {
        let downloadState = state(chapterId: chapter.id)

        return downloadService.isReady && chapter.locked != true
            && (downloadState == nil || downloadState == .cancelled)
    }

    private func hasDownload(_ chapter: Chapter) -> Bool {
        let downloadState = state(chapterId: chapter.id)
        return downloadState != nil && downloadState != .cancelled
    }

    private func buildDownloadPayload() -> ChapterGroups {
        var result: ChapterGroups = []
        for (groupIndex, group) in detailedManga.chapters.enumerated() {
            guard let selectedIds = selectedChapters[groupIndex], !selectedIds.isEmpty else {
                continue
            }
            result.append(
                ChapterGroup(
                    id: group.id, title: group.title,
                    chapters: group.chapters.filter {
                        selectedIds.contains($0.id) && isSelectable($0)
                    }))
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                ChapterSelector(
                    groups: detailedManga.chapters, selection: chapterSelection,
                    isSelectable: isSelectable, isPreselected: hasDownload
                ) { chapter in chapterRow(chapter: chapter) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("close") { dismiss() } }

                ToolbarItem(placement: .confirmationAction) {
                    Button("download") {
                        let payload = buildDownloadPayload()
                        downloadChapters(payload)
                        dismiss()
                    }
                    .disabled(totalSelectedCount == 0)
                }
            }
            .navigationTitleWithSubtitle(
                title: Text("selectChapters"),
                subtitle: totalSelectedCount > 0
                    ? Text(
                        String(
                            format: String(localized: "selectedChapterCountFormat"),
                            totalSelectedCount)) : nil)
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.hidden)
        .task {
            do { try await downloadService.start() } catch {
                NotificationService.shared.showError(error.localizedDescription)
            }
        }
    }

    @ViewBuilder private func chapterRow(chapter: Chapter) -> some View {
        let downloadState = state(chapterId: chapter.id)
        let hasDownload = downloadState != nil && downloadState != .cancelled

        HStack {
            Text(chapter.title ?? chapter.id).foregroundColor(hasDownload ? .secondary : .primary)

            Spacer()

            if let downloadState, downloadState != .cancelled {
                Text(downloadState.label).font(.caption).foregroundColor(.secondary)
            } else if chapter.locked == true {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }
        }
    }
}
