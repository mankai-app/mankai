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

    var body: some View {
        VStack(alignment: .leading) {
            NavigationLink(destination: {
                if let query = query {
                    SourceSearchScreen(plugin: plugin, query: query)
                } else {
                    SourceLibraryScreen(plugin: plugin)
                }
            }) {
                HStack(spacing: 4) {
                    Text(plugin.name ?? plugin.id).font(.title3).foregroundColor(.primary)
                        .fontWeight(.semibold)
                    Image(systemName: "chevron.right").font(.callout).foregroundColor(.secondary)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let mangas = mangas {
                if mangas.isEmpty {
                    Text("noMangasAvailable").foregroundColor(.secondary)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: horizontalSizeClass == .regular ? 240 : 200,
                            alignment: .center)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(mangas) { manga in
                                if plugin.supports(.mangaDetails) {
                                    NavigationLink(
                                        destination: MangaDetailsScreen(
                                            plugin: plugin, manga: manga)
                                    ) {
                                        MangaItemView(manga: manga, plugin: plugin)
                                            .frame(
                                                width: horizontalSizeClass == .regular ? 144 : 120)
                                    }
                                } else {
                                    MangaItemView(manga: manga, plugin: plugin)
                                        .frame(width: horizontalSizeClass == .regular ? 144 : 120)
                                }
                            }
                        }
                    }
                    .frame(minHeight: horizontalSizeClass == .regular ? 240 : 200)
                }
            } else {
                ProgressView()
                    .frame(
                        maxWidth: .infinity, minHeight: horizontalSizeClass == .regular ? 240 : 200,
                        alignment: .center)
            }
        }
    }
}
