//
//  HistoryScreen.swift
//  mankai
//
//  Created by Travis XU on 12/7/2025.
//

import SwiftUI

struct HistoryScreen: View {
    @State private var progressEntries: [ProgressModel] = []
    @State private var isLoading = false
    @State private var hasLoadedAll = false

    private let batchSize = 25

    var body: some View {
        NavigationStack {
            Group {
                if progressEntries.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "noHistory", systemImage: "clock.badge.xmark",
                        description: Text("noHistoryDescription"))
                } else {
                    List {
                        Section {
                            ForEach(Array(progressEntries.enumerated()), id: \.offset) {
                                index, progress in
                                HistoryItemView(progress: progress)
                                    .onAppear {
                                        if index == progressEntries.count - 1 && !hasLoadedAll {
                                            loadMoreProgress()
                                        }
                                    }
                            }

                            if isLoading { ProgressView().frame(maxWidth: .infinity) }
                        } header: {
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .navigationTitle("history").navigationBarTitleDisplayMode(.inline)
            .onAppear { if progressEntries.isEmpty { loadInitialProgress() } }
            .onReceive(ProgressService.shared.objectWillChange) { refreshProgress() }
        }
    }

    private func loadInitialProgress() {
        progressEntries = []
        hasLoadedAll = false
        loadMoreProgress()
    }

    private func loadMoreProgress() {
        guard !isLoading, !hasLoadedAll else { return }

        isLoading = true

        let newProgressEntries = ProgressService.shared.getAll(
            limit: batchSize, offset: progressEntries.count)

        progressEntries.append(contentsOf: newProgressEntries)
        hasLoadedAll = newProgressEntries.count < batchSize
        isLoading = false
    }

    private func refreshProgress() {
        let newProgressEntries = ProgressService.shared.getAll(limit: progressEntries.count)
        progressEntries = newProgressEntries
    }
}

struct HistoryItemView: View {
    var progress: ProgressModel

    @State private var manga: Manga?
    @State private var plugin: Plugin?
    @State private var isLoading: Bool = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                NavigationLink(destination: {
                    if let manga = manga, let plugin = plugin {
                        MangaDetailsScreen(plugin: plugin, manga: manga)
                    } else {
                        ContentUnavailableView {
                            Label("somethingWentWrong", systemImage: "exclamationmark.circle")
                        } description: {
                            Text("failedToLoadMangaDetails")
                        }
                    }
                }) {
                    HStack(spacing: 12) {
                        MangaCoverView(coverUrl: manga?.cover, plugin: plugin)
                            .aspectRatio(3 / 4, contentMode: .fit)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(manga?.title ?? progress.mangaId).lineLimit(1)

                                if !progress.shouldSync {
                                    Image("custom.arrow.trianglehead.2.clockwise.rotate.90.slash")
                                        .foregroundStyle(.orange).font(.subheadline)
                                }
                            }

                            HStack(spacing: 4) {
                                if let chapterTitle = progress.chapterTitle {
                                    Text(chapterTitle)
                                } else {
                                    Text(
                                        String(
                                            format: String(localized: "chapterFormat"),
                                            progress.chapterId))
                                }

                                Text(verbatim: "•")
                                Text(
                                    String(
                                        format: String(localized: "historyPageFormat"),
                                        progress.page + 1))
                            }
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)

                            Text(progress.datetime.formatted()).font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .frame(height: 100).task { await loadMangaData() }
    }

    private func loadMangaData() async {
        plugin =
            PluginService.shared.getPlugin(progress.pluginId)
            ?? BrowseService.shared.getPlugin(progress.pluginId)

        manga = MangaSnapshotService.shared.get(
            mangaId: progress.mangaId, pluginId: progress.pluginId)

        // If not found locally, try fetching from plugin
        if manga == nil, let plugin = plugin,
            plugin.supports(.batchMangas) || plugin.supports(.mangaDetails)
        {
            do {
                let fetchedManga: Manga
                if plugin.supports(.batchMangas) {
                    fetchedManga = try await plugin.getManga(id: progress.mangaId)
                } else {
                    fetchedManga = try await plugin.getDetailedManga(progress.mangaId).toManga()
                }

                try Task.checkCancellation()
                manga = fetchedManga
            } catch is CancellationError { return } catch {
                Logger.ui.error("Failed to fetch manga from plugin", error: error)
            }
        }

        isLoading = false

        if manga == nil { Logger.ui.warning("Failed to load manga for progress: \(progress)") }
    }
}
