//
//  FilesScreen.swift
//  mankai
//
//  Created by Travis XU on 14/7/2026.
//

import SwiftUI

struct FilesScreen: View {
    private struct TopRightCornerTriangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }

    let share: BrowsablePlugin
    let entry: Entity?
    let color: Color?

    @Environment(\.openURL) private var openURL
    @AppStorage(SettingsKey.filesViewMode.rawValue) private var viewModeRawValue = SettingsDefaults
        .filesViewMode.rawValue

    @State private var entities: [Entity] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var isParsing: Bool = false
    @State private var parsedMangas: [String: DetailedManga] = [:]
    @State private var unreadMangaPaths: Set<String> = []
    @State private var parsingPaths: Set<String> = []
    @State private var parseErrors: [String: String] = [:]

    init(share: BrowsablePlugin, entry: Entity? = nil, color: Color? = nil) {
        self.share = share
        self.entry = entry
        self.color = color ?? share.color
    }

    var body: some View {
        ScrollView {
            if viewMode == .grid {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 100), spacing: 20, alignment: .top)],
                    spacing: 20
                ) {
                    ForEach(Array(entities.enumerated()), id: \.offset) { _, entity in
                        switch entity.type { case .directory:
                            NavigationLink(destination: FilesScreen(share: share, entry: entity)) {
                                directoryView(entity: entity)
                            }
                            .buttonStyle(.plain)
                            case .book:
                                if let manga = parsedMangas[entity.path] {
                                    NavigationLink(
                                        destination: MangaDetailsScreen(
                                            plugin: share, manga: manga.toManga())
                                    ) {
                                        mangaView(
                                            manga: manga, entity: entity,
                                            isUnread: unreadMangaPaths.contains(entity.path))
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    filePlaceholderView(
                                        entity: entity,
                                        isParsing: parsingPaths.contains(entity.path),
                                        errorMessage: parseErrors[entity.path])
                                }
                        }
                    }
                }
                .padding()
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entities.enumerated()), id: \.offset) { index, entity in
                        switch entity.type { case .directory:
                            NavigationLink(destination: FilesScreen(share: share, entry: entity)) {
                                directoryListView(entity: entity)
                            }
                            .buttonStyle(.plain)
                            case .book(let fileType):
                                if let manga = parsedMangas[entity.path] {
                                    NavigationLink(
                                        destination: MangaDetailsScreen(
                                            plugin: share, manga: manga.toManga())
                                    ) {
                                        mangaListView(
                                            manga: manga, entity: entity, fileType: fileType,
                                            isUnread: unreadMangaPaths.contains(entity.path))
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    filePlaceholderListView(
                                        entity: entity, fileType: fileType,
                                        isParsing: parsingPaths.contains(entity.path),
                                        errorMessage: parseErrors[entity.path])
                                }
                        }

                        if index < entities.count - 1 { Divider().padding(.leading, 72) }
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle(navigationTitle).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: toggleViewMode) {
                    Label(
                        viewMode == .grid ? "listView" : "gridView",
                        systemImage: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if folderURL != nil {
                    Button {
                        openInFilesApp()
                    } label: {
                        Label("openInFiles", systemImage: "folder")
                    }
                }
            }
        }
        .overlay {
            if isLoading && entities.isEmpty {
                ProgressView {
                    Text("filesScreenLoadingHint").multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else if let errorMessage = errorMessage {
                ContentUnavailableView(
                    "failedToLoadList", systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            } else if entities.isEmpty {
                ContentUnavailableView(
                    "noEntities", systemImage: "tray", description: Text("noEntitiesDescription"))
            }
        }
        .task { await loadEntities() }
    }

    private var viewMode: FilesViewMode {
        FilesViewMode(rawValue: viewModeRawValue) ?? SettingsDefaults.filesViewMode
    }

    private var navigationTitle: String {
        if let entry { return entry.displayName }
        return share.name ?? share.id
    }

    private var folderURL: URL? { share.absoluteURL(for: entry?.path) }

    private func toggleViewMode() {
        viewModeRawValue =
            viewMode == .grid ? FilesViewMode.list.rawValue : FilesViewMode.grid.rawValue
    }

    private func openInFilesApp() {
        guard let folderURL else { return }
        let path = folderURL.standardizedFileURL.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        if let url = URL(string: "shareddocuments://\(encoded)") { openURL(url) }
    }

    private func loadEntities() async {
        guard !isLoading, !isParsing else { return }

        isLoading = true
        errorMessage = nil
        parsedMangas = [:]
        unreadMangaPaths = []
        parsingPaths = []
        parseErrors = [:]

        defer {
            isLoading = false
            isParsing = false
        }

        do {
            try Task.checkCancellation()
            let result = try await share.getEntities(path: entry?.path)

            let sorted = result.sorted { lhs, rhs in
                switch (lhs.type, rhs.type) { case (.directory, .book): return true
                    case (.book, .directory): return false
                    default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
            entities = sorted
            isLoading = false
            isParsing = true

            for entity in sorted {
                guard case .book(let fileType) = entity.type else { continue }
                let filePath = entity.path

                parsingPaths.insert(filePath)

                do {
                    try Task.checkCancellation()
                    let manga = try await share.parseFile(path: filePath, fileType: fileType)

                    let isUnread =
                        ProgressService.shared.get(mangaId: manga.id, pluginId: share.id) == nil
                    parsedMangas[filePath] = manga
                    if isUnread { unreadMangaPaths.insert(filePath) }
                    parsingPaths.remove(filePath)
                } catch is CancellationError {
                    parsingPaths.remove(filePath)
                    return
                } catch {
                    parseErrors[filePath] = error.localizedDescription
                    parsingPaths.remove(filePath)
                }
            }
        } catch is CancellationError { return } catch { errorMessage = error.localizedDescription }
    }

    private func thumbnailView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Color.clear.aspectRatio(3 / 4, contentMode: .fit)
            .overlay { content().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private func directoryView(entity: Entity) -> some View {
        VStack(spacing: 8) {
            thumbnailView {
                Image("FolderIcon").resizable().scaledToFit()
                    .overlay {
                        Image("FolderIcon").renderingMode(.template).resizable().scaledToFit()
                            .foregroundStyle(color ?? .accentColor).blendMode(.hue)
                    }
                    .compositingGroup()
            }

            Text(entity.displayName).font(.caption).foregroundColor(.primary).lineLimit(2)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
    }

    private func mangaView(manga: DetailedManga, entity: Entity, isUnread: Bool) -> some View {
        VStack(spacing: 8) {
            thumbnailView { mangaThumbnail(manga: manga, isUnread: isUnread) }

            Text(entity.displayName(using: manga)).font(.caption).foregroundColor(.primary)
                .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
    }

    private func listThumbnail<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Color.clear.frame(width: 56, height: 72)
            .overlay { content().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private func directoryListView(entity: Entity) -> some View {
        HStack(spacing: 16) {
            listThumbnail {
                Image("FolderIcon").resizable().scaledToFit()
                    .overlay {
                        Image("FolderIcon").renderingMode(.template).resizable().scaledToFit()
                            .foregroundStyle(color ?? .accentColor).blendMode(.hue)
                    }
                    .compositingGroup()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(entity.displayName).font(.body).foregroundStyle(.primary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8).contentShape(Rectangle())
    }

    private func mangaListView(
        manga: DetailedManga, entity: Entity, fileType: String, isUnread: Bool
    ) -> some View {
        HStack(spacing: 16) {
            listThumbnail {
                mangaThumbnail(
                    manga: manga, isUnread: isUnread, cornerRadius: 6, showsUnreadTag: false)
            }

            bookListMetadata(
                title: entity.displayName(using: manga), entity: entity, fileType: fileType)

            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8).contentShape(Rectangle())
    }

    private func mangaThumbnail(
        manga: DetailedManga, isUnread: Bool, cornerRadius: CGFloat? = nil,
        showsUnreadTag: Bool = true
    ) -> some View {
        let effectiveCornerRadius: CGFloat =
            if let cornerRadius { cornerRadius } else if #available(iOS 26.0, *) { 12 } else { 8 }

        return MangaCoverView(
            coverUrl: manga.cover, plugin: share,
            tag: isUnread && showsUnreadTag ? String(localized: "unread") : nil,
            tagColor: isUnread && showsUnreadTag ? .orange : nil, cornerRadius: cornerRadius
        )
        .overlay {
            RoundedRectangle(cornerRadius: effectiveCornerRadius)
                .strokeBorder(Color(uiColor: .separator))
        }
        .overlay {
            if isUnread && !showsUnreadTag {
                GeometryReader { proxy in
                    let markerSize = min(proxy.size.width, proxy.size.height) * 0.35

                    TopRightCornerTriangle().fill(.orange).opacity(0.9)
                        .frame(width: markerSize, height: markerSize)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: effectiveCornerRadius))
    }

    private func filePlaceholderListView(
        entity: Entity, fileType: String, isParsing: Bool, errorMessage: String?
    ) -> some View {
        HStack(spacing: 16) {
            listThumbnail {
                documentThumbnail(
                    fileType: fileType, isParsing: isParsing, hasError: errorMessage != nil)
            }

            VStack(alignment: .leading, spacing: 6) {
                bookListMetadata(title: entity.displayName, entity: entity, fileType: fileType)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").font(.caption)
                        .foregroundStyle(.orange).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8).contentShape(Rectangle())
    }

    private func bookListMetadata(title: String, entity: Entity, fileType: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.body).foregroundStyle(.primary).lineLimit(2)

            HStack(spacing: 8) {
                Text(entity.name).lineLimit(1)
                Spacer(minLength: 0)
                Text(fileType.uppercased()).smallTagStyle()
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filePlaceholderView(entity: Entity, isParsing: Bool, errorMessage: String?)
        -> some View
    {
        let fileType: String
        if case .book(let type) = entity.type { fileType = type } else { fileType = "" }

        return VStack(spacing: 8) {
            thumbnailView {
                documentThumbnail(
                    fileType: fileType, isParsing: isParsing, hasError: errorMessage != nil)
            }

            Text(entity.displayName).font(.caption).foregroundColor(.primary).lineLimit(2)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
        .help(errorMessage ?? "")
    }

    private func documentThumbnail(fileType: String, isParsing: Bool, hasError: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            Image("DocumentIcon").resizable().scaledToFill().clipped()

            if hasError {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                    .padding(12).background(.regularMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isParsing {
                ProgressView().padding(12).background(.regularMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text(fileType.uppercased()).font(.caption2).fontWeight(.semibold)
                .foregroundStyle(hasError ? Color.orange : Color.primary).padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(12)
        }
    }
}
