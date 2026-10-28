//
//  MangasRowListView.swift
//  mankai
//
//  Created by Travis XU on 27/6/2025.
//

import SwiftUI

struct MangasRowListView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let mangas: [Manga]?
    let plugin: Plugin
    var query: String? = nil
    let onRead: (ReaderRoute) -> Void

    @State private var isUpdateMangaModalPresented = false

    private var canCreateManga: Bool { query == nil && plugin is any Editable }

    var body: some View {
        VStack(alignment: .leading) {
            NavigationLink(destination: {
                if let query = query {
                    SourceSearchScreen(plugin: plugin, query: query)
                } else {
                    SourceLibraryScreen(plugin: plugin)
                }
            }) {
                HStack {
                    plugin.iconView.scaleEffect(24.0 / 28.0).frame(width: 24, height: 24)

                    Text(plugin.name ?? plugin.id).font(.title3).foregroundColor(.primary)
                        .fontWeight(.semibold)
                    Image(systemName: "chevron.right").font(.callout).foregroundColor(.secondary)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let mangas = mangas {
                if mangas.isEmpty && !canCreateManga {
                    Text("noMangasAvailable").foregroundColor(.secondary)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: horizontalSizeClass == .regular ? 240 : 200,
                            alignment: .center)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(mangas) { manga in
                                MangaItemView(manga: manga, plugin: plugin, onRead: onRead)
                                    .frame(width: horizontalSizeClass == .regular ? 144 : 120)
                            }

                            if canCreateManga {
                                createMangaButton.frame(
                                    width: horizontalSizeClass == .regular ? 144 : 120)
                            }
                        }
                    }
                    .scrollClipDisabled()
                    .frame(minHeight: horizontalSizeClass == .regular ? 240 : 200)
                }
            } else {
                ProgressView()
                    .frame(
                        maxWidth: .infinity, minHeight: horizontalSizeClass == .regular ? 240 : 200,
                        alignment: .center)
            }
        }
        .sheet(isPresented: $isUpdateMangaModalPresented) {
            if let editablePlugin = plugin as? any Editable {
                UpdateMangaModal(plugin: editablePlugin)
            }
        }
    }

    private var createMangaButton: some View {
        Button {
            isUpdateMangaModalPresented = true
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: coverCornerRadius).fill(Color(.systemGray6))
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .overlay { Image(systemName: "plus").font(.title) }

                Text("createManga").font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var coverCornerRadius: CGFloat {
        if #available(iOS 26.0, *) { return 12 }
        return 8
    }
}
