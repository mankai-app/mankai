//
//  SelectChaptersModal.swift
//  mankai
//
//  Created by Travis XU on 14/2/2026.
//

import GRDB
import SwiftUI

struct SelectChaptersModal: View {
    @Environment(\.dismiss) var dismiss
    let plugin: Plugin
    let detailedManga: DetailedManga

    @ObservedObject private var downloadService = DownloadService.shared

    let downloadChapters: (ChapterGroups) -> Void

    // Chapter-group index -> set of selected chapter IDs.
    @State private var selectedChapters: [Int: Set<String>] = [:]
    @State private var expandedGroupIndex: Int? = nil

    private var totalSelectedCount: Int { buildDownloadPayload().flatMap(\.chapters).count }

    private func state(chapterId: String) -> DownloadState? {
        downloadService.chapterState(
            pluginId: plugin.id, mangaId: detailedManga.id, chapterId: chapterId)
    }

    private func isSelectable(_ chapter: Chapter) -> Bool {
        let downloadState = state(chapterId: chapter.id)

        return downloadService.isReady && chapter.locked != true
            && (downloadState == nil || downloadState == .cancelled)
    }

    private func isSelected(chapterId: String, groupIndex: Int) -> Bool {
        selectedChapters[groupIndex]?.contains(chapterId) == true
    }

    private func toggleChapter(_ chapter: Chapter, groupIndex: Int) {
        guard isSelectable(chapter) else { return }

        var set = selectedChapters[groupIndex] ?? []
        if set.contains(chapter.id) { set.remove(chapter.id) } else { set.insert(chapter.id) }
        selectedChapters[groupIndex] = set
    }

    private func selectAllInGroup(_ groupIndex: Int, chapters: [Chapter]) {
        let selectable = chapters.filter(isSelectable)
        let selectableIds = Set(selectable.map { $0.id })
        let currentSelected = selectedChapters[groupIndex] ?? []

        if selectableIds.isSubset(of: currentSelected) {
            selectedChapters[groupIndex] = currentSelected.subtracting(selectableIds)
        } else {
            selectedChapters[groupIndex] = currentSelected.union(selectableIds)
        }
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
                ForEach(Array(detailedManga.chapters.enumerated()), id: \.offset) {
                    groupIndex, group in
                    Section {
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedGroupIndex == groupIndex },
                                set: { isExpanded in
                                    expandedGroupIndex = isExpanded ? groupIndex : nil
                                })
                        ) {
                            ForEach(group.chapters, id: \.id) { chapter in
                                chapterRow(chapter: chapter, groupIndex: groupIndex)
                            }
                        } label: {
                            chapterGroupRow(
                                groupIndex: groupIndex, groupTitle: group.title,
                                chapters: group.chapters)
                        }
                    }
                }
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

    @ViewBuilder private func chapterGroupRow(
        groupIndex: Int, groupTitle: String, chapters: [Chapter]
    ) -> some View {
        // calculate selectable chapters (those without an existing download)
        let selectableChapters = chapters.filter(isSelectable)
        let selectableCount = selectableChapters.count

        // calculate currently selected count among selectable ones
        let currentlySelectedIds = selectedChapters[groupIndex] ?? []
        let selectedSelectableCount =
            selectableChapters.filter { currentlySelectedIds.contains($0.id) }.count

        let isAllSelected = selectableCount > 0 && selectedSelectableCount == selectableCount
        let isPartiallySelected =
            selectedSelectableCount > 0 && selectedSelectableCount < selectableCount

        HStack(spacing: 12) {
            // Select All / Deselect All Checkbox
            if selectableCount > 0 {
                Button(action: { selectAllInGroup(groupIndex, chapters: chapters) }) {
                    Image(
                        systemName: isAllSelected
                            ? "checkmark.circle.fill"
                            : (isPartiallySelected ? "minus.circle.fill" : "circle")
                    )
                    .resizable().frame(width: 20, height: 20)
                    .foregroundColor(
                        isAllSelected || isPartiallySelected
                            ? .accentColor : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            } else {
                // No selectable chapters
                Image(systemName: "checkmark.circle.fill").resizable().frame(width: 20, height: 20)
                    .foregroundColor(.gray)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(groupTitle)).foregroundColor(.primary)

                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "chapterCountFormat"), chapters.count)
                    )
                    .smallTagStyle()
                }

                Text(
                    String(
                        format: String(localized: "selectedChapterCountFormat"),
                        selectedSelectableCount)
                )
                .font(.caption).foregroundColor(.accentColor)
            }

            Spacer()
        }
        .padding(.trailing, 4)
    }

    @ViewBuilder private func chapterRow(chapter: Chapter, groupIndex: Int) -> some View {
        let downloadState = state(chapterId: chapter.id)
        let hasDownload = downloadState != nil && downloadState != .cancelled
        let selected = hasDownload || isSelected(chapterId: chapter.id, groupIndex: groupIndex)
        let selectable = isSelectable(chapter)

        Button(action: { toggleChapter(chapter, groupIndex: groupIndex) }) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(hasDownload ? .gray : selected ? .accentColor : .secondary)

                Text(chapter.title ?? chapter.id)
                    .foregroundColor(hasDownload ? .secondary : .primary)

                Spacer()

                if let downloadState, downloadState != .cancelled {
                    Text(downloadState.label).font(.caption).foregroundColor(.secondary)
                } else if chapter.locked == true {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!selectable)
    }
}
