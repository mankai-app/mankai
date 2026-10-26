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
        private var isApplyingVisibility = false
        private var visibilityUpdateScheduled = false
        private weak var controlledTabBarController: UITabBarController?
        private var wasTabBarHidden = false

        private final class AttachmentView: UIView {
            var onWindowChanged: ((Bool) -> Void)?

            override func didMoveToWindow() {
                super.didMoveToWindow()
                onWindowChanged?(window != nil)
            }
        }

        override func loadView() {
            let attachmentView = AttachmentView()
            attachmentView.backgroundColor = .clear
            attachmentView.isUserInteractionEnabled = false
            attachmentView.onWindowChanged = { [weak self] isAttached in
                guard let self else { return }
                if isAttached {
                    self.isVisible = true
                    self.scheduleVisibilityUpdate()
                } else {
                    self.restoreTabBar(animated: false)
                }
            }
            view = attachmentView
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isVisible = true
            applyVisibility(animated: animated)
            scheduleVisibilityUpdate()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            applyVisibility(animated: false)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if isVisible { applyVisibility(animated: false) }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restoreTabBar(animated: animated)
        }

        func setTabBarHidden(_ isHidden: Bool) {
            shouldHideTabBar = isHidden
            if #available(iOS 26.0, *), isVisible { applyVisibility(animated: true) }
            scheduleVisibilityUpdate()
        }

        private func scheduleVisibilityUpdate() {
            guard isVisible, !visibilityUpdateScheduled else { return }
            visibilityUpdateScheduled = true
            // Apply after SwiftUI has updated the List and its bottom toolbar.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.visibilityUpdateScheduled = false
                if self.isVisible { self.applyVisibility(animated: false) }
            }
        }

        private func applyVisibility(animated: Bool) {
            guard isVisible, !isApplyingVisibility else { return }
            isApplyingVisibility = true
            defer { isApplyingVisibility = false }

            guard let tabBarController else { return }

            if controlledTabBarController == nil {
                // Capture the browsing state before selection adds the bottom toolbar.
                controlledTabBarController = tabBarController
                if #available(iOS 18.0, *) {
                    wasTabBarHidden = tabBarController.isTabBarHidden
                } else {
                    wasTabBarHidden = tabBarController.tabBar.isHidden
                }
            }
            setHidden(shouldHideTabBar || wasTabBarHidden, on: tabBarController, animated: animated)
        }

        func restoreTabBar(animated: Bool) {
            isVisible = false
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
            }
            if #unavailable(iOS 26.0) {
                // Keep the tab bar view in sync with the controller on older SwiftUI versions.
                tabBarController.tabBar.isHidden = isHidden
            }
        }
    }
}

struct FilesScreen: View {
    private enum FileAction {
        case download, delete, bookmark, removeBookmark, removeRecords

        var title: LocalizedStringKey {
            switch self { case .download: return "download" case .delete: return "delete"
                case .bookmark: return "bookmark"
                case .removeBookmark: return "removeBookmark"
                case .removeRecords: return "removeRecords"
            }
        }

        var confirmationMessage: LocalizedStringKey? {
            switch self { case .download: return nil case .delete: return "deleteFilesConfirmation"
                case .bookmark: return "bookmarkFilesConfirmation"
                case .removeBookmark: return "removeBookmarksConfirmation"
                case .removeRecords: return "removeRecordsConfirmation"
            }
        }

        var role: ButtonRole? { self == .delete || self == .removeRecords ? .destructive : nil }

        var requiresManga: Bool {
            switch self { case .download, .delete: return false
                case .bookmark, .removeBookmark, .removeRecords: return true
            }
        }
    }

    private struct PendingBatchAction {
        let action: FileAction
        let entries: [Entity]
    }

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

    @ObservedObject private var libraryService = LibraryService.shared

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
    @State private var pendingBatchAction: PendingBatchAction?
    @State private var activeFileAction: FileAction?

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
        GeometryReader { geometry in
            if showsStatusView {
                ScrollView {
                    // Measure the viewport outside the scroll content to avoid List row clipping.
                    statusView.fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: geometry.size.height)
                }
            } else if viewMode == .grid {
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
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable {
            guard !isBusy else { return }
            refreshId = UUID()
        }
        .navigationTitle(navigationTitle).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSelecting)
        .overlay {
            FilesTabBarController(isHidden: isSelecting).frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
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
                    if #available(iOS 26.0, *) {
                        Button("done", systemImage: "checkmark") {
                            withAnimation { editMode = .inactive }
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle).disabled(isBusy)
                    } else {
                        Button("done") { withAnimation { editMode = .inactive } }.disabled(isBusy)
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    if #unavailable(iOS 26.0) { Spacer() }

                    Button("download", systemImage: "arrow.down") { requestBatchAction(.download) }
                        .disabled(selectedPaths.isEmpty || isBusy)

                    if #unavailable(iOS 26.0) { Spacer() }

                    Group {
                        if allSelectedFilesBookmarked {
                            Button("removeBookmark", systemImage: "bookmark.slash") {
                                requestBatchAction(.removeBookmark)
                            }
                        } else {
                            Button("bookmark", systemImage: "bookmark") {
                                requestBatchAction(.bookmark)
                            }
                        }

                        if #unavailable(iOS 26.0) { Spacer() }

                        Button(
                            "removeRecords", systemImage: "clock.badge.xmark", role: .destructive
                        ) { requestBatchAction(.removeRecords) }
                    }
                    .disabled(!canPerformBatchMangaAction || isBusy)

                    if share is any FileDeletable {
                        if #unavailable(iOS 26.0) { Spacer() }

                        Button("delete", systemImage: "trash", role: .destructive) {
                            requestBatchAction(.delete)
                        }
                        .disabled(selectedPaths.isEmpty || isBusy)
                    }

                    Spacer()
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section {
                            Button("select", systemImage: "checkmark.circle") {
                                withAnimation { editMode = .active }
                            }
                            .disabled(selectableFilePaths.isEmpty || isBusy)

                            if folderURL != nil {
                                Button("openInFiles", systemImage: "folder") { openInFilesApp() }
                            }
                        }

                        Picker(selection: $viewModeRawValue) {
                            Label("gridView", systemImage: "square.grid.2x2")
                                .tag(FilesViewMode.grid.rawValue)
                            Label("listView", systemImage: "list.bullet")
                                .tag(FilesViewMode.list.rawValue)
                        } label: {
                            Label(
                                viewMode == .grid ? "gridView" : "listView",
                                systemImage: viewMode == .grid ? "square.grid.2x2" : "list.bullet")
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label {
                            Text("actions")
                        } icon: {
                            ToolbarIcon(systemName: "ellipsis", legacySystemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { _, mode in if !mode.isEditing { selectedPaths.removeAll() } }
        .confirmationDialog(
            pendingBatchAction?.action.title ?? "actions",
            isPresented: .init(
                get: { pendingBatchAction != nil }, set: { if !$0 { pendingBatchAction = nil } }),
            titleVisibility: .visible, presenting: pendingBatchAction
        ) { request in
            Button(request.action.title, role: request.action.role) {
                Task { await performFileAction(request.action, for: request.entries) }
            }
            Button("cancel", role: .cancel) {}
        } message: { request in
            if let message = request.action.confirmationMessage { Text(message) }
        }
        .task(id: refreshId) { await loadEntities() }
        .onReceive(share.objectWillChange) { if activeFileAction != .delete { refreshId = UUID() } }
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

    private var showsStatusView: Bool { entities.isEmpty || errorMessage != nil }

    private var statusView: some View {
        Group {
            if isLoading && entities.isEmpty {
                ProgressView {
                    Text("filesScreenLoadingHint").multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "failedToLoadList", systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            } else {
                ContentUnavailableView(
                    "noEntities", systemImage: "tray", description: Text("noEntitiesDescription"))
            }
        }
        .frame(maxWidth: .infinity)
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

    private var isBusy: Bool { activeFileAction != nil }

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

    private var canPerformBatchMangaAction: Bool {
        !selectedPaths.isEmpty && selectedEntities.allSatisfy { parsedMangas[$0.path] != nil }
    }

    private var allSelectedFilesBookmarked: Bool {
        guard canPerformBatchMangaAction else { return false }
        return selectedEntities.allSatisfy { entity in
            guard let manga = parsedMangas[entity.path] else { return false }
            return libraryService.get(mangaId: manga.id, pluginId: share.id) != nil
        }
    }

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
                download: { Task { await performFileAction(.download, for: [entity]) } },
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
        guard share is any FileDeletable else { return nil }
        return { await performFileAction(.delete, for: [entity]) }
    }

    private func requestBatchAction(_ action: FileAction) {
        let entries = selectedEntities
        guard !isBusy, !entries.isEmpty else { return }
        if action == .download {
            Task { await performFileAction(action, for: entries) }
        } else {
            pendingBatchAction = PendingBatchAction(action: action, entries: entries)
        }
    }

    @MainActor private func performFileAction(_ action: FileAction, for entries: [Entity]) async {
        guard !isBusy, !entries.isEmpty else { return }
        let deletableShare = share as? any FileDeletable
        guard action != .delete || deletableShare != nil else { return }
        let items = entries.map { (entity: $0, manga: parsedMangas[$0.path]) }
        guard !action.requiresManga || items.allSatisfy({ $0.manga != nil }) else { return }

        activeFileAction = action
        defer {
            activeFileAction = nil
            if action == .delete { refreshId = UUID() }
        }

        var files: [ParserFile] = []
        var unavailableNames: [String] = []
        var failures: [String] = []

        for (entity, manga) in items {
            do {
                switch action { case .download:
                    if let file = try await share.parserFile(path: entity.path) {
                        files.append(file)
                    } else {
                        unavailableNames.append(entity.displayName(using: manga))
                    }
                    case .delete:
                        if let deletableShare {
                            try await deletableShare.deleteFile(path: entity.path)
                        }
                    case .bookmark:
                        guard let manga else { continue }
                        if LibraryService.shared.get(mangaId: manga.id, pluginId: share.id) == nil {
                            let snapshot = MangaSnapshotService.shared.makeSnapshot(
                                for: manga.toManga(), pluginId: share.id)
                            try await MangaSnapshotService.shared.upsert(snapshot)
                            let libraryItem = LibraryModel(
                                mangaId: manga.id, pluginId: share.id, datetime: Date(),
                                updates: false, latestChapter: manga.latestChapter,
                                shouldSync: share.supports(.sync))
                            _ = try await LibraryService.shared.save(libraryItem: libraryItem)
                        }
                    case .removeBookmark:
                        guard let manga else { continue }
                        if LibraryService.shared.get(mangaId: manga.id, pluginId: share.id) != nil {
                            _ = try await LibraryService.shared.remove(
                                mangaId: manga.id, pluginId: share.id)
                        }
                    case .removeRecords:
                        guard let manga else { continue }
                        _ = try await ProgressService.shared.remove(
                            mangaId: manga.id, pluginId: share.id)
                }
                selectedPaths.remove(entity.path)
            } catch {
                Logger.ui.error("Failed to perform file action for \(entity.path)", error: error)
                failures.append(
                    "\(entity.displayName(using: manga)): \(error.localizedDescription)")
            }
        }

        if selectedPaths.isEmpty { withAnimation { editMode = .inactive } }
        if action == .download, !files.isEmpty || !unavailableNames.isEmpty {
            filesToDownload = files
            unavailableFileNames = unavailableNames
            isDownloadFilesModalPresented = true
        }
        if !failures.isEmpty {
            NotificationService.shared.showError(failures.joined(separator: "\n"))
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

    private func openInFilesApp() {
        guard let folderURL else { return }

        let path = folderURL.standardizedFileURL.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path

        if let url = URL(string: "shareddocuments://\(encoded)") { UIApplication.shared.open(url) }
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
