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
    @State private var parsingProgress: [String: Double] = [:]
    @State private var loadId: UUID?
    @State private var parseErrors: [String: String] = [:]

    @State private var editMode: EditMode = .inactive
    @State private var selectedPaths: Set<String> = []

    @State private var isPreparingDownloads = false
    @State private var filesToDownload: [ParserFile] = []
    @State private var unavailableFileNames: [String] = []
    @State private var isDownloadFilesModalPresented = false
    @State private var openDownloadsAfterDismiss = false
    @State private var isDownloadsFolderPresented = false

    init(share: BrowsablePlugin, entry: Entity? = nil, color: Color? = nil) {
        self.share = share
        self.entry = entry
        self.color = color ?? share.color
    }

    var body: some View {
        Group {
            if viewMode == .grid {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 100), spacing: 20, alignment: .top)],
                        spacing: 20
                    ) {
                        ForEach(Array(entities.enumerated()), id: \.offset) { _, entity in
                            switch entity.type { case .directory:
                                NavigationLink(
                                    destination: FilesScreen(share: share, entry: entity)
                                ) { directoryView(entity: entity) }
                                .buttonStyle(.plain).disabled(isSelecting)

                                case .book(let fileType):
                                    bookView(entity: entity, fileType: fileType)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                List(selection: isSelecting ? $selectedPaths : nil) {
                    ForEach(entities, id: \.path) { entity in
                        switch entity.type { case .directory:
                            NavigationLink(destination: FilesScreen(share: share, entry: entity)) {
                                directoryListView(entity: entity)
                            }
                            .buttonStyle(.plain).disabled(isSelecting).selectionDisabled()

                            case .book(let fileType):
                                bookView(entity: entity, fileType: fileType).tag(entity.path)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain).disabled(isPreparingDownloads)
            }
        }
        .navigationTitle(navigationTitle).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSelecting {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("download", systemImage: "arrow.down") {
                        prepareDownloads(for: entities.filter { selectedPaths.contains($0.path) })
                    }
                    .disabled(selectedPaths.isEmpty || isPreparingDownloads)

                    EditButton().disabled(isPreparingDownloads)
                }
            } else {
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
        }
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { _, mode in if !mode.isEditing { selectedPaths.removeAll() } }

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
        .sheet(
            isPresented: $isDownloadFilesModalPresented,
            onDismiss: {
                if openDownloadsAfterDismiss {
                    openDownloadsAfterDismiss = false
                    isDownloadsFolderPresented = true
                }
            }
        ) { [filesToDownload, unavailableFileNames] in
            DownloadFilesModal(files: filesToDownload, unavailableFileNames: unavailableFileNames) {
                openDownloadsAfterDismiss = true
            }
        }
        .navigationDestination(isPresented: $isDownloadsFolderPresented) {
            FilesScreen(
                share: AppDirBrowsablePlugin.shared,
                entry: Entity(
                    path: "dowloads", displayName: String(localized: "downloads"), name: "dowloads",
                    type: .directory))
        }
    }

    private var viewMode: FilesViewMode {
        FilesViewMode(rawValue: viewModeRawValue) ?? SettingsDefaults.filesViewMode
    }

    private var navigationTitle: String {
        if let entry { return entry.displayName }
        return share.name ?? share.id
    }

    private var folderURL: URL? { share.absoluteURL(for: entry?.path) }

    private var isSelecting: Bool { editMode.isEditing }

    private func bookView(entity: Entity, fileType: String) -> some View {
        Group {
            if isSelecting {
                if viewMode == .grid {
                    Button {
                        if !selectedPaths.insert(entity.path).inserted {
                            selectedPaths.remove(entity.path)
                        }
                    } label: {
                        bookContent(entity: entity, fileType: fileType)
                    }
                    .disabled(isPreparingDownloads)
                } else {
                    bookContent(entity: entity, fileType: fileType)
                }
            } else if let manga = parsedMangas[entity.path] {
                NavigationLink(
                    destination: MangaDetailsScreen(plugin: share, manga: manga.toManga()) {
                        isDownloadsFolderPresented = true
                    }
                ) { bookContent(entity: entity, fileType: fileType) }
            } else {
                bookContent(entity: entity, fileType: fileType)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("download", systemImage: "arrow.down") { prepareDownloads(for: [entity]) }
                .disabled(isPreparingDownloads)

            Button {
                withAnimation {
                    if isSelecting {
                        editMode = .inactive
                    } else {
                        selectedPaths = [entity.path]
                        editMode = .active
                    }
                }
            } label: {
                Label {
                    if isSelecting { Text("done") } else { Text("select") }
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            }
            .disabled(isPreparingDownloads)
        }
    }

    private func bookContent(entity: Entity, fileType: String) -> some View {
        Group {
            if viewMode == .grid {
                if let manga = parsedMangas[entity.path] {
                    mangaView(
                        manga: manga, entity: entity,
                        isUnread: unreadMangaPaths.contains(entity.path))
                } else {
                    filePlaceholderView(
                        entity: entity, isParsing: parsingPaths.contains(entity.path),
                        errorMessage: parseErrors[entity.path])
                }
            } else {
                if let manga = parsedMangas[entity.path] {
                    mangaListView(
                        manga: manga, entity: entity, fileType: fileType,
                        isUnread: unreadMangaPaths.contains(entity.path))
                } else {
                    filePlaceholderListView(
                        entity: entity, fileType: fileType,
                        isParsing: parsingPaths.contains(entity.path),
                        errorMessage: parseErrors[entity.path])
                }
            }
        }
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if isSelecting, viewMode == .grid { selectionIndicator(for: entity).padding(8) }
        }
    }

    private func selectionIndicator(for entity: Entity) -> some View {
        Image(systemName: selectedPaths.contains(entity.path) ? "checkmark.circle.fill" : "circle")
            .font(.title2).foregroundStyle(.tint).background(.background, in: Circle())
    }

    private func prepareDownloads(for entries: [Entity]) {
        guard !isPreparingDownloads, !entries.isEmpty else { return }

        withAnimation { editMode = .inactive }

        isPreparingDownloads = true

        Task { @MainActor in
            defer { isPreparingDownloads = false }

            do {
                var files: [ParserFile] = []
                var unavailableNames: [String] = []

                for entity in entries {
                    if let file = try await share.parserFile(path: entity.path) {
                        files.append(file)
                    } else {
                        unavailableNames.append(
                            entity.displayName(using: parsedMangas[entity.path]))
                    }
                }

                filesToDownload = files
                unavailableFileNames = unavailableNames
                isDownloadFilesModalPresented = true
            } catch { NotificationService.shared.showError(error.localizedDescription) }
        }
    }

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

        let currentLoadId = UUID()
        loadId = currentLoadId
        isLoading = true
        errorMessage = nil
        parsedMangas = [:]
        unreadMangaPaths = []
        parsingPaths = []
        parsingProgress = [:]
        parseErrors = [:]

        defer {
            loadId = nil
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
                defer {
                    parsingPaths.remove(filePath)
                    parsingProgress.removeValue(forKey: filePath)
                }

                do {
                    try Task.checkCancellation()
                    let manga = try await share.parseFile(
                        path: filePath, fileType: fileType,
                        progress: { value in
                            Task { @MainActor in
                                guard loadId == currentLoadId, parsingPaths.contains(filePath)
                                else { return }
                                parsingProgress[filePath] = value
                            }
                        })

                    let isUnread =
                        ProgressService.shared.get(mangaId: manga.id, pluginId: share.id) == nil
                    parsedMangas[filePath] = manga
                    if isUnread { unreadMangaPaths.insert(filePath) }
                } catch is CancellationError { return } catch {
                    parseErrors[filePath] = error.localizedDescription
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
                    fileType: fileType, isParsing: isParsing,
                    progress: parsingProgress[entity.path], hasError: errorMessage != nil)
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
                    fileType: fileType, isParsing: isParsing,
                    progress: parsingProgress[entity.path], hasError: errorMessage != nil)
            }

            Text(entity.displayName).font(.caption).foregroundColor(.primary).lineLimit(2)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
        .help(errorMessage ?? "")
    }

    private func documentThumbnail(
        fileType: String, isParsing: Bool, progress: Double?, hasError: Bool
    ) -> some View {
        ZStack(alignment: .bottomLeading) {
            Image("DocumentIcon").resizable().scaledToFill().clipped()

            if hasError {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                    .padding(12).background(.regularMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isParsing {
                ProgressView(value: progress).progressViewStyle(.circular).padding(12)
                    .background(.regularMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text(fileType.uppercased()).font(.caption2).fontWeight(.semibold)
                .foregroundStyle(hasError ? Color.orange : Color.primary).padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(12)
        }
    }
}
