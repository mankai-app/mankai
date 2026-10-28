//
//  ChapterSelector.swift
//  mankai
//
//  Created by Travis XU on 26/10/2026.
//

import SwiftUI

struct ChapterSelection: Hashable {
    let groupIndex: Int
    let chapterId: String
}

struct ChapterSelector<ChapterRow: View>: View {
    let groups: ChapterGroups
    @Binding var selection: Set<ChapterSelection>
    var isSelectable: (Chapter) -> Bool = { _ in true }
    var isPreselected: (Chapter) -> Bool = { _ in false }
    var footer: Text? = nil
    let chapterRow: (Chapter) -> ChapterRow

    @State private var expandedGroupIndex: Int?

    var body: some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
            Section {
                groupRow(group, index: groupIndex)

                if expandedGroupIndex == groupIndex {
                    ForEach(group.chapters, id: \.id) { chapter in
                        selectableChapterRow(chapter, groupIndex: groupIndex)
                    }
                }
            } footer: {
                if let footer { footer }
            }
        }
    }

    private func groupRow(_ group: ChapterGroup, index: Int) -> some View {
        let chapterSelections = Set(
            group.chapters.filter(isSelectable)
                .map { ChapterSelection(groupIndex: index, chapterId: $0.id) })
        let selectedCount = chapterSelections.intersection(selection).count
        let allSelected = !chapterSelections.isEmpty && selectedCount == chapterSelections.count

        return HStack(spacing: 12) {
            if chapterSelections.isEmpty {
                Image(systemName: "checkmark.circle.fill").resizable().frame(width: 20, height: 20)
                    .foregroundColor(.gray)
            } else {
                Button {
                    if allSelected {
                        selection.subtract(chapterSelections)
                    } else {
                        selection.formUnion(chapterSelections)
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
            }

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

    private func selectableChapterRow(_ chapter: Chapter, groupIndex: Int) -> some View {
        let chapterSelection = ChapterSelection(groupIndex: groupIndex, chapterId: chapter.id)
        let preselected = isPreselected(chapter)
        let selected = preselected || selection.contains(chapterSelection)

        return Button {
            guard isSelectable(chapter) else { return }
            if selection.contains(chapterSelection) {
                selection.remove(chapterSelection)
            } else {
                selection.insert(chapterSelection)
            }
        } label: {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(preselected ? .gray : selected ? .accentColor : .secondary)

                chapterRow(chapter).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(!isSelectable(chapter))
    }
}
