//
//  MangaItemView.swift
//  mankai
//
//  Created by Travis XU on 28/6/2025.
//

import SwiftUI

struct MangaItemView: View {
    let manga: Manga
    let plugin: Plugin
    var progress: ProgressModel? = nil
    var libraryItem: LibraryModel? = nil
    var showsUnreadTag: Bool = false

    private var latestChapter: Chapter? {
        guard let libraryItem else { return manga.latestChapter }
        return libraryItem.latestChapter ?? manga.latestChapter
    }

    private var isUnread: Bool { showsUnreadTag && progress == nil }

    private var coverTag: (text: String, color: Color)? {
        if libraryItem?.updates == true { return (String(localized: "new"), .green) }
        if isUnread { return (String(localized: "unread"), .orange) }
        if manga.status == .completed { return (String(localized: "mangaCompleted"), .red) }
        return nil
    }

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            // Cover Image
            MangaCoverView(
                coverUrl: manga.cover, plugin: plugin, tag: coverTag?.text,
                tagColor: coverTag?.color
            )
            .aspectRatio(3 / 4, contentMode: .fit)

            VStack(alignment: .center) {
                // Title
                if let title = manga.title {
                    Text(title).font(.caption).foregroundColor(.primary).lineLimit(1)
                }

                // Latest Chapter
                HStack(spacing: 4) {
                    if let progress = progress {
                        if let title = progress.chapterTitle {
                            Text(title)
                        } else {
                            Text(
                                String(
                                    format: String(localized: "chapterFormat"), progress.chapterId))
                        }

                        Text(verbatim: "/")
                    }

                    if let latestChapter {
                        if let title = latestChapter.title {
                            Text(title)

                        } else {
                            Text(
                                String(format: String(localized: "chapterFormat"), latestChapter.id)
                            )
                        }
                    }
                }
                .font(.caption2).foregroundColor(.secondary).foregroundStyle(.secondary)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}
