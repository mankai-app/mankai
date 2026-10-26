//
//  FilesScreen.swift
//  mankai
//
//  Created by Travis XU on 14/7/2026.
//

import SwiftUI
import UIKit

private struct FilesTabBarController: UIViewControllerRepresentable {
    let isHidden: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.setTabBarHidden(isHidden)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restoreTabBar(animated: false)
    }

    final class Controller: UIViewController {
        private var shouldHideTabBar = false
        private var isVisible = false
        private weak var controlledTabBarController: UITabBarController?
        private var wasTabBarHidden = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isVisible = true
            applyVisibility(animated: animated)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyVisibility(animated: false)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if isVisible { applyVisibility(animated: false) }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            isVisible = false
            restoreTabBar(animated: animated)
        }

        func setTabBarHidden(_ isHidden: Bool) {
            shouldHideTabBar = isHidden
            if isVisible { applyVisibility(animated: true) }
        }

        private func applyVisibility(animated: Bool) {
            guard shouldHideTabBar else {
                restoreTabBar(animated: animated)
                return
            }
            guard let tabBarController else { return }

            if controlledTabBarController == nil {
                controlledTabBarController = tabBarController
                if #available(iOS 18.0, *) {
                    wasTabBarHidden = tabBarController.isTabBarHidden
                } else {
                    wasTabBarHidden = tabBarController.tabBar.isHidden
                }
            }
            setHidden(true, on: tabBarController, animated: animated)
        }

        func restoreTabBar(animated: Bool) {
            guard let tabBarController = controlledTabBarController else { return }
            controlledTabBarController = nil
            setHidden(wasTabBarHidden, on: tabBarController, animated: animated)
        }

        private func setHidden(
            _ isHidden: Bool, on tabBarController: UITabBarController, animated: Bool
        ) {
            if #available(iOS 18.0, *) {
                if tabBarController.isTabBarHidden != isHidden {
                    tabBarController.setTabBarHidden(isHidden, animated: animated)
                }
            } else {
                tabBarController.tabBar.isHidden = isHidden
            }
        }
    }
}

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

    @State private var parsedMangas: [String: DetailedManga] = [:]
    @State private var unreadMangaPaths: Set<String> = []
    @State private var parsingPaths: Set<String> = []
    @State private var parsingProgress: [String: Double] = [:]
    @State private var loadId: UUID?
    @State private var refreshId = UUID()
    @State private var parseErrors: [String: String] = [:]
    @State private var readerRoute: ReaderRoute?

    @State private var editMode: EditMode = .inactive
    @State private var selectedPaths: Set<String> = []
    @State private var showingDeleteConfirmation = false
    @State private var isDeletingFiles = false

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
                        ForEach(entities, id: \.path) { entity in
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
                .listStyle(.plain).disabled(isBusy)
            }
        }
        .navigationTitle(navigationTitle).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSelecting)
        .background { FilesTabBarController(isHidden: isSelecting).frame(width: 0, height: 0) }
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(allFilesSelected ? "deselectAll" : "selectAll") {
                        withAnimation {
                            selectedPaths = allFilesSelected ? [] : selectableFilePaths
                        }
                    }
                    .disabled(selectableFilePaths.isEmpty || isBusy)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("done", systemImage: "checkmark") {
                        withAnimation { editMode = .inactive }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle).disabled(isBusy)
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    Button("download", systemImage: "arrow.down") {
                        prepareDownloads(for: selectedEntities)
                    }
                    .disabled(selectedPaths.isEmpty || isBusy)

                    if share is any FileDeletable {
                        Button("delete", systemImage: "trash", role: .destructive) {
                            showingDeleteConfirmation = true
                        }
                        .disabled(selectedPaths.isEmpty || isBusy)
                    }

                    Spacer()
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
        .confirmationDialog(
            "delete", isPresented: $showingDeleteConfirmation, titleVisibility: .visible
        ) {
            Button("delete", role: .destructive, action: deleteSelectedFiles)
            Button("cancel", role: .cancel) {}
        } message: {
            Text("deleteFilesConfirmation")
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
        .task(id: refreshId) { await loadEntities() }
        .onReceive(share.objectWillChange) { if !isDeletingFiles { refreshId = UUID() } }
        .onReceive(ProgressService.shared.objectWillChange) { updateUnreadMangas() }
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
        .navigationDestination(item: $readerRoute) { route in
            ReaderScreen(
                plugin: route.plugin, manga: route.manga, downloadManga: route.downloadManga,
                usesDownloadedMetadata: route.usesDownloadedMetadata,
                chapterGroupIndex: route.chapterGroupIndex, chapter: route.chapter,
                initialPage: route.initialPage)
        }
    }

    private var viewMode: FilesViewMode {
        FilesViewMode(rawValue: viewModeRawValue) ?? SettingsDefaults.filesViewMode
    }

    private var navigationTitle: String {
        if isSelecting {
            return String(format: String(localized: "selectedFileCountFormat"), selectedPaths.count)
        }

        if let entry { return entry.displayName }
        return share.name ?? share.id
    }

    private var folderURL: URL? { share.absoluteURL(for: entry?.path) }

    private var isSelecting: Bool { editMode.isEditing }

    private var isBusy: Bool { isPreparingDownloads || isDeletingFiles }

    private var selectableFilePaths: Set<String> {
        Set(
            entities.compactMap { entity in
                guard case .book = entity.type else { return nil }
                return entity.path
            })
    }

    private var allFilesSelected: Bool {
        !selectableFilePaths.isEmpty && selectableFilePaths.isSubset(of: selectedPaths)
    }

    private var selectedEntities: [Entity] { entities.filter { selectedPaths.contains($0.path) } }

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
                    .disabled(isBusy)
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
    }

    private func bookContextMenu(for entity: Entity) -> MangaItemContextMenu {
        MangaItemContextMenu(
            manga: parsedMangas[entity.path]?.toManga(), plugin: share,
            onRead: { readerRoute = $0 },
            fileActions: .init(
                isSelecting: isSelecting, isBusy: isBusy,
                download: { prepareDownloads(for: [entity]) },
                select: { toggleSelection(for: entity) }, delete: fileDeletionAction(for: entity)))
    }

    private func toggleSelection(for entity: Entity) {
        withAnimation {
            if isSelecting {
                editMode = .inactive
            } else {
                selectedPaths = [entity.path]
                editMode = .active
            }
        }
    }

    private func fileDeletionAction(for entity: Entity) -> (() async throws -> Void)? {
        guard let deletableShare = share as? any FileDeletable else { return nil }
        return { try await deletableShare.deleteFile(path: entity.path) }
    }

    private func deleteSelectedFiles() {
        let entries = selectedEntities
        guard !isBusy, !entries.isEmpty, let deletableShare = share as? any FileDeletable else {
            return
        }

        isDeletingFiles = true

        Task { @MainActor in
            defer {
                isDeletingFiles = false
                refreshId = UUID()
            }

            var failures: [String] = []
            for entity in entries {
                do {
                    try await deletableShare.deleteFile(path: entity.path)
                    selectedPaths.remove(entity.path)
                } catch {
                    Logger.ui.error("Failed to delete file \(entity.path)", error: error)
                    failures.append("\(entity.displayName): \(error.localizedDescription)")
                }
            }

            if selectedPaths.isEmpty { withAnimation { editMode = .inactive } }
            if !failures.isEmpty {
                NotificationService.shared.showError(failures.joined(separator: "\n"))
            }
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
                        isUnread: unreadMangaPaths.contains(entity.path)
                    )
                    .modifier(bookContextMenu(for: entity))
                } else {
                    filePlaceholderListView(
                        entity: entity, fileType: fileType,
                        isParsing: parsingPaths.contains(entity.path),
                        errorMessage: parseErrors[entity.path]
                    )
                    .modifier(bookContextMenu(for: entity))
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func selectionIndicator(for entity: Entity) -> some View {
        let isSelected = selectedPaths.contains(entity.path)

        return Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .foregroundStyle(isSelected ? Color.accentColor : Color(uiColor: .tertiaryLabel))
            .background(.background, in: Circle())
            .overlay { if isSelected { Circle().strokeBorder(.white, lineWidth: 1) } }
    }

    private func prepareDownloads(for entries: [Entity]) {
        guard !isBusy, !entries.isEmpty else { return }

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
            if loadId == currentLoadId {
                loadId = nil
                isLoading = false
            }
        }

        do {
            try Task.checkCancellation()
            let result = try await share.getEntities(path: entry?.path)
            try Task.checkCancellation()
            guard loadId == currentLoadId else { return }

            let sorted = result.sorted { lhs, rhs in
                switch (lhs.type, rhs.type) { case (.directory, .book): return true
                    case (.book, .directory): return false
                    default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
            entities = sorted
            selectedPaths.formIntersection(selectableFilePaths)
            isLoading = false

            for entity in sorted {
                guard case .book(let fileType) = entity.type else { continue }
                let filePath = entity.path

                parsingPaths.insert(filePath)
                defer {
                    if loadId == currentLoadId {
                        parsingPaths.remove(filePath)
                        parsingProgress.removeValue(forKey: filePath)
                    }
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
                    try Task.checkCancellation()
                    guard loadId == currentLoadId else { return }

                    let isUnread =
                        ProgressService.shared.get(mangaId: manga.id, pluginId: share.id) == nil
                    parsedMangas[filePath] = manga
                    if isUnread { unreadMangaPaths.insert(filePath) }
                } catch is CancellationError { return } catch {
                    guard loadId == currentLoadId, !Task.isCancelled else { return }
                    parseErrors[filePath] = error.localizedDescription
                }
            }
        } catch is CancellationError { return } catch {
            guard loadId == currentLoadId, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func updateUnreadMangas() {
        unreadMangaPaths = Set(
            parsedMangas.compactMap { path, manga in
                ProgressService.shared.get(mangaId: manga.id, pluginId: share.id) == nil
                    ? path : nil
            })
    }

    private func thumbnailView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Color.clear.aspectRatio(3 / 4, contentMode: .fit)
            .overlay { content().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private func selectableThumbnail<Content: View>(
        for entity: Entity, @ViewBuilder content: () -> Content
    ) -> some View {
        thumbnailView { content().padding(isSelecting ? 8 : 0) }
            .background {
                if isSelecting && selectedPaths.contains(entity.path) {
                    RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .tertiarySystemFill))
                }
            }
            .overlay(alignment: .bottom) {
                if isSelecting { selectionIndicator(for: entity).padding(.bottom, 24) }
            }
    }

    private func gridTitle(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.primary).lineLimit(2)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
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
            selectableThumbnail(for: entity) { mangaThumbnail(manga: manga, isUnread: isUnread) }
                .modifier(bookContextMenu(for: entity))

            gridTitle(entity.displayName(using: manga))
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
            selectableThumbnail(for: entity) {
                documentThumbnail(
                    fileType: fileType, isParsing: isParsing,
                    progress: parsingProgress[entity.path], hasError: errorMessage != nil)
            }
            .modifier(bookContextMenu(for: entity))

            gridTitle(entity.displayName)
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
