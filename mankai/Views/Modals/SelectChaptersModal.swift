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
    let alreadyDownloaded: Set<String>?
    let downloadChapters: (ChapterGroups) -> Void

    // Chapter-group index -> set of selected chapter IDs.
    @State private var selectedChapters: [Int: Set<String>] = [:]
    @State private var expandedGroupIndex: Int? = nil

    private var totalSelectedCount: Int { selectedChapters.values.reduce(0) { $0 + $1.count } }

    private func isDownloaded(chapterId: String) -> Bool {
        alreadyDownloaded?.contains(chapterId) == true
    }

    private func isSelected(chapterId: String, groupIndex: Int) -> Bool {
        selectedChapters[groupIndex]?.contains(chapterId) == true
    }

    private func toggleChapter(_ chapter: Chapter, groupIndex: Int) {
        var set = selectedChapters[groupIndex] ?? []
        if set.contains(chapter.id) { set.remove(chapter.id) } else { set.insert(chapter.id) }
        selectedChapters[groupIndex] = set
    }

    private func selectAllInGroup(_ groupIndex: Int, chapters: [Chapter]) {
        let selectable = chapters.filter { !isDownloaded(chapterId: $0.id) }
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
                    chapters: group.chapters.filter { selectedIds.contains($0.id) }))
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(detailedManga.chapters.enumerated()), id: \.offset) {
                    groupIndex, group in
                    Section {
                        chapterGroupRow(
                            groupIndex: groupIndex, groupTitle: group.title,
                            chapters: group.chapters)

                        if expandedGroupIndex == groupIndex {
                            ForEach(group.chapters, id: \.id) { chapter in
                                chapterRow(chapter: chapter, groupIndex: groupIndex)
                            }
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
    }

    @ViewBuilder private func chapterGroupRow(
        groupIndex: Int, groupTitle: String, chapters: [Chapter]
    ) -> some View {
        // calculate selectable chapters (those not already downloaded)
        let selectableChapters = chapters.filter { !isDownloaded(chapterId: $0.id) }
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
                // Fully downloaded state
                Image(systemName: "checkmark.circle.fill").resizable().frame(width: 20, height: 20)
                    .foregroundColor(.gray)
            }

            // Group Title and Info (Tapping this area toggles expansion)
            HStack {
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

                Image(systemName: "chevron.right").font(.footnote).foregroundColor(.secondary)
                    .rotationEffect(.degrees(expandedGroupIndex == groupIndex ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation {
                    if expandedGroupIndex == groupIndex {
                        expandedGroupIndex = nil
                    } else {
                        expandedGroupIndex = groupIndex
                    }
                }
            }
        }
        .padding(.trailing, 4)
    }

    @ViewBuilder private func chapterRow(chapter: Chapter, groupIndex: Int) -> some View {
        let downloaded = isDownloaded(chapterId: chapter.id)
        let selected = isSelected(chapterId: chapter.id, groupIndex: groupIndex)

        Button(action: { toggleChapter(chapter, groupIndex: groupIndex) }) {
            HStack {
                Image(
                    systemName: downloaded
                        ? "checkmark.circle.fill" : selected ? "checkmark.circle.fill" : "circle"
                )
                .foregroundColor(downloaded ? .gray : selected ? .accentColor : .secondary)

                Text(chapter.title ?? chapter.id)
                    .foregroundColor(downloaded ? .secondary : .primary)

                Spacer()

                if downloaded { Text("downloaded").font(.caption).foregroundColor(.secondary) }
            }
        }
        .disabled(downloaded)
    }
}
