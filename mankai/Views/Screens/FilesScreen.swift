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
        private var animatesVisibilityUpdate = false
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
            scheduleVisibilityUpdate(animated: animated)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            scheduleVisibilityUpdate()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            scheduleVisibilityUpdate()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restoreTabBar(animated: animated)
        }

        func setTabBarHidden(_ isHidden: Bool) {
            guard shouldHideTabBar != isHidden else { return }
            shouldHideTabBar = isHidden
            if #available(iOS 26.0, *) {
                scheduleVisibilityUpdate(animated: true)
            } else {
                scheduleVisibilityUpdate()
            }
        }

        private func scheduleVisibilityUpdate(animated: Bool = false) {
            guard isVisible else { return }
            animatesVisibilityUpdate = animatesVisibilityUpdate || animated
            guard !visibilityUpdateScheduled else { return }
            visibilityUpdateScheduled = true

            // Changing tab-bar layout during a SwiftUI update can reenter its attribute graph.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let animated = self.animatesVisibilityUpdate
                self.animatesVisibilityUpdate = false
                self.visibilityUpdateScheduled = false
                if self.isVisible { self.applyVisibility(animated: animated) }
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
            animatesVisibilityUpdate = false
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
                if tabBarController.tabBar.isHidden != isHidden {
                    tabBarController.tabBar.isHidden = isHidden
                }
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

        var systemImage: String {
            switch self { case .download: return "arrow.down" case .delete: return "trash"
                case .bookmark: return "bookmark"
                case .removeBookmark: return "bookmark.slash"
                case .removeRecords: return "clock.badge.xmark"
            }
        }

        var role: ButtonRole? { self == .delete || self == .removeRecords ? .destructive : nil }

        var requiresManga: Bool {
            switch self { case .download, .delete: return false
                case .bookmark, .removeBookmark, .removeRecords: return true
            }
        }
    }

    private struct FileItem: Identifiable {
        enum ParseState {
            case queued
            case parsing(Double?)
            case ready(DetailedManga, isUnread: Bool)
            case failed(String)
        }

        let entity: Entity
        var state: ParseState = .queued

        var id: String { entity.path }

        var fileType: String? {
            guard case .book(let fileType) = entity.type else { return nil }
            return fileType
        }

        var manga: DetailedManga? {
            guard case .ready(let manga, _) = state else { return nil }
            return manga
        }

        var isUnread: Bool {
            guard case .ready(_, let isUnread) = state else { return false }
            return isUnread
        }

        var errorMessage: String? {
            guard case .failed(let message) = state else { return nil }
            return message
        }

        var displayName: String { entity.displayName(using: manga) }
    }

    private enum ListingState {
        case loading
        case loaded
        case failed(String)
    }

    private struct PendingBatchAction {
        let action: FileAction
        let items: [FileItem]
    }

    private struct DownloadRequest: Identifiable {
        let id = UUID()
        var files: [ParserFile] = []
        var unavailableNames: [String] = []

        var isEmpty: Bool { files.isEmpty && unavailableNames.isEmpty }
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

    @State private var items: [FileItem] = []
    @State private var listingState: ListingState = .loading
    @State private var loadId: UUID?
    @State private var refreshId = UUID()
    @State private var readerRoute: ReaderRoute?

    @State private var editMode: EditMode = .inactive
    @State private var selectedPaths: Set<String> = []
    @State private var pendingBatchAction: PendingBatchAction?
    @State private var activeFileAction: FileAction?

    @State private var downloadRequest: DownloadRequest?
    @State private var openDownloadsAfterDismiss = false
    @State private var isDownloadsFolderPresented = false

    init(share: BrowsablePlugin, entry: Entity? = nil, color: Color? = nil) {
        self.share = share
        self.entry = entry
        self.color = color ?? share.color
    }

    var body: some View {
        content.scrollBounceBehavior(.always, axes: .vertical)
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
            .toolbar { fileToolbar }.environment(\.editMode, $editMode)
            .onChange(of: editMode) { _, mode in if !mode.isEditing { selectedPaths.removeAll() } }
            .confirmationDialog(
                pendingBatchAction?.action.title ?? "actions",
                isPresented: .init(
                    get: { pendingBatchAction != nil }, set: { if !$0 { pendingBatchAction = nil } }
                ), titleVisibility: .visible, presenting: pendingBatchAction
            ) { request in
                Button(request.action.title, role: request.action.role) {
                    Task { await performFileAction(request.action, for: request.items) }
                }
                Button("cancel", role: .cancel) {}
            } message: { request in
                if let message = request.action.confirmationMessage { Text(message) }
            }
            .task(id: refreshId) { await loadEntities() }
            .onReceive(share.objectWillChange) {
                if activeFileAction != .delete { refreshId = UUID() }
            }
            .onReceive(ProgressService.shared.changes) { updateUnreadMangas($0) }
            .sheet(
                item: $downloadRequest,
                onDismiss: {
                    if openDownloadsAfterDismiss {
                        openDownloadsAfterDismiss = false
                        isDownloadsFolderPresented = true
                    }
                }
            ) { request in
                DownloadFilesModal(
                    files: request.files, unavailableFileNames: request.unavailableNames
                ) { openDownloadsAfterDismiss = true }
            }
            .navigationDestination(isPresented: $isDownloadsFolderPresented) {
                FilesScreen(
                    share: AppDirBrowsablePlugin.shared,
                    entry: Entity(
                        path: "dowloads", displayName: String(localized: "downloads"),
                        name: "dowloads", type: .directory))
            }
            .navigationDestination(item: $readerRoute) { route in
                ReaderScreen(
                    plugin: route.plugin, manga: route.manga, downloadManga: route.downloadManga,
                    usesDownloadedMetadata: route.usesDownloadedMetadata,
                    chapterGroupIndex: route.chapterGroupIndex, chapter: route.chapter,
                    initialPage: route.initialPage)
            }
    }

    // MARK: - Content

    private var content: some View {
        GeometryReader { geometry in
            if showsStatusView {
                ScrollView {
                    // Measure the viewport outside the scroll content to avoid List row clipping.
                    statusView.fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: geometry.size.height)
                }
            } else if viewMode == .grid {
                gridView
            } else {
                listView
            }
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100), spacing: 20, alignment: .top)],
                spacing: 20
            ) { fileRows }
            .padding()
        }
    }

    private var listView: some View {
        List(selection: isSelecting ? $selectedPaths : nil) {
            fileRows.listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain).disabled(isBusy)
    }

    private var fileRows: some View {
        ForEach(items) { item in
            if let fileType = item.fileType {
                bookView(item, fileType: fileType).tag(item.id)
            } else {
                NavigationLink(destination: FilesScreen(share: share, entry: item.entity)) {
                    if viewMode == .grid {
                        directoryGridView(entity: item.entity)
                    } else {
                        directoryListView(entity: item.entity)
                    }
                }
                .disabled(isSelecting).selectionDisabled()
            }
        }
        .buttonStyle(.plain)
    }

    private var showsStatusView: Bool {
        if case .failed = listingState { return true }
        return items.isEmpty
    }

    private var statusView: some View {
        Group {
            switch listingState { case .loading:
                ProgressView {
                    Text("filesScreenLoadingHint").multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                case .failed(let message):
                    ContentUnavailableView(
                        "failedToLoadList", systemImage: "exclamationmark.triangle",
                        description: Text(message))
                case .loaded:
                    ContentUnavailableView(
                        "noEntities", systemImage: "tray",
                        description: Text("noEntitiesDescription"))
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

    // MARK: - Toolbar and selection

    @ToolbarContentBuilder private var fileToolbar: some ToolbarContent {
        let selectablePaths = selectableFilePaths
        let selected = items.filter { selectedPaths.contains($0.id) }
        let allSelected = !selectablePaths.isEmpty && selectablePaths.isSubset(of: selectedPaths)
        let mangas = selected.compactMap(\.manga)
        let allBookmarked =
            !selected.isEmpty && mangas.count == selected.count
            && mangas.allSatisfy { libraryService.get(mangaId: $0.id, pluginId: share.id) != nil }

        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(allSelected ? "deselectAll" : "selectAll") {
                    withAnimation { selectedPaths = allSelected ? [] : selectablePaths }
                }
                .disabled(selectablePaths.isEmpty || isBusy)
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

                fileActionButton(.download, for: selected)

                if #unavailable(iOS 26.0) { Spacer() }

                fileActionButton(allBookmarked ? .removeBookmark : .bookmark, for: selected)

                if #unavailable(iOS 26.0) { Spacer() }

                fileActionButton(.removeRecords, for: selected)

                if share is any FileDeletable {
                    if #unavailable(iOS 26.0) { Spacer() }

                    fileActionButton(.delete, for: selected)
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
                        .disabled(selectablePaths.isEmpty || isBusy)

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

    private var selectableFilePaths: Set<String> {
        Set(items.filter { $0.fileType != nil }.map(\.id))
    }

    private func fileActionButton(_ action: FileAction, for items: [FileItem]) -> some View {
        Button(action.title, systemImage: action.systemImage, role: action.role) {
            requestBatchAction(action, for: items)
        }
        .disabled(!canPerform(action, on: items))
    }

    private func canPerform(_ action: FileAction, on items: [FileItem]) -> Bool {
        !isBusy && !items.isEmpty && (action != .delete || share is any FileDeletable)
            && (!action.requiresManga || items.allSatisfy { $0.manga != nil })
    }

    // MARK: - File actions

    private func bookContextMenu(for item: FileItem) -> MangaItemContextMenu {
        MangaItemContextMenu(
            manga: item.manga?.toManga(), plugin: share, onRead: { readerRoute = $0 },
            fileActions: .init(
                isSelecting: isSelecting, isBusy: isBusy,
                download: { Task { await performFileAction(.download, for: [item]) } },
                select: { toggleSelectionMode(startingWith: item) },
                delete: fileDeletionAction(for: item)))
    }

    private func toggleSelectionMode(startingWith item: FileItem) {
        withAnimation {
            if isSelecting {
                editMode = .inactive
            } else {
                selectedPaths = [item.id]
                editMode = .active
            }
        }
    }

    private func fileDeletionAction(for item: FileItem) -> (() async throws -> Void)? {
        guard share is any FileDeletable else { return nil }
        return { await performFileAction(.delete, for: [item]) }
    }

    private func requestBatchAction(_ action: FileAction, for items: [FileItem]) {
        guard canPerform(action, on: items) else { return }
        if action.confirmationMessage != nil {
            pendingBatchAction = PendingBatchAction(action: action, items: items)
        } else {
            Task { await performFileAction(action, for: items) }
        }
    }

    @MainActor private func performFileAction(_ action: FileAction, for items: [FileItem]) async {
        guard canPerform(action, on: items) else { return }
        let deletableShare = share as? any FileDeletable

        activeFileAction = action
        defer {
            activeFileAction = nil
            if action == .delete { refreshId = UUID() }
        }

        var downloads = DownloadRequest()
        var failures: [String] = []

        for item in items {
            do {
                switch action { case .download:
                    if let file = try await share.parserFile(path: item.id) {
                        downloads.files.append(file)
                    } else {
                        downloads.unavailableNames.append(item.displayName)
                    }
                    case .delete:
                        if let deletableShare { try await deletableShare.deleteFile(path: item.id) }
                    case .bookmark:
                        if let manga = item.manga,
                            libraryService.get(mangaId: manga.id, pluginId: share.id) == nil
                        {
                            try await bookmark(manga)
                        }
                    case .removeBookmark:
                        if let manga = item.manga,
                            libraryService.get(mangaId: manga.id, pluginId: share.id) != nil
                        {
                            _ = try await libraryService.remove(
                                mangaId: manga.id, pluginId: share.id)
                        }
                    case .removeRecords:
                        if let manga = item.manga {
                            _ = try await ProgressService.shared.remove(
                                mangaId: manga.id, pluginId: share.id)
                        }
                }
                selectedPaths.remove(item.id)
            } catch {
                Logger.ui.error("Failed to perform file action for \(item.id)", error: error)
                failures.append("\(item.displayName): \(error.localizedDescription)")
            }
        }

        if selectedPaths.isEmpty { withAnimation { editMode = .inactive } }
        if !downloads.isEmpty { downloadRequest = downloads }
        if !failures.isEmpty {
            NotificationService.shared.showError(failures.joined(separator: "\n"))
        }
    }

    private func bookmark(_ manga: DetailedManga) async throws {
        let snapshot = MangaSnapshotService.shared.makeSnapshot(
            for: manga.toManga(), pluginId: share.id)
        try await MangaSnapshotService.shared.upsert(snapshot)
        let libraryItem = LibraryModel(
            mangaId: manga.id, pluginId: share.id, datetime: Date(), updates: false,
            latestChapter: manga.latestChapter, shouldSync: share.supports(.sync))
        _ = try await libraryService.save(libraryItem: libraryItem)
    }

    private func openInFilesApp() {
        guard let folderURL else { return }

        let path = folderURL.standardizedFileURL.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path

        if let url = URL(string: "shareddocuments://\(encoded)") { UIApplication.shared.open(url) }
    }

    // MARK: - Loading

    private func loadEntities() async {
        let currentLoadId = UUID()
        loadId = currentLoadId
        listingState = .loading
        for index in items.indices { items[index].state = .queued }

        defer {
            if loadId == currentLoadId {
                loadId = nil
                if case .loading = listingState { listingState = .loaded }
            }
        }

        do {
            try Task.checkCancellation()
            let entities = try await share.getEntities(path: entry?.path)
            try Task.checkCancellation()
            guard loadId == currentLoadId else { return }

            items =
                entities.sorted { lhs, rhs in
                    switch (lhs.type, rhs.type) { case (.directory, .book): return true
                        case (.book, .directory): return false
                        default:
                            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                }
                .map { FileItem(entity: $0) }
            selectedPaths.formIntersection(selectableFilePaths)
            listingState = .loaded

            // Indices stay stable during a load, the ID rejects callbacks after a refresh.
            for index in items.indices {
                let item = items[index]
                guard let fileType = item.fileType else { continue }
                items[index].state = .parsing(nil)

                defer {
                    if loadId == currentLoadId, case .parsing = items[index].state {
                        items[index].state = .queued
                    }
                }

                do {
                    try Task.checkCancellation()
                    let manga = try await share.parseFile(
                        path: item.id, fileType: fileType,
                        progress: { value in
                            Task { @MainActor in
                                guard loadId == currentLoadId, case .parsing = items[index].state
                                else { return }
                                items[index].state = .parsing(value)
                            }
                        })
                    try Task.checkCancellation()
                    guard loadId == currentLoadId else { return }

                    items[index].state = .ready(
                        manga,
                        isUnread: ProgressService.shared.get(mangaId: manga.id, pluginId: share.id)
                            == nil)
                } catch is CancellationError { return } catch {
                    guard loadId == currentLoadId, !Task.isCancelled else { return }
                    items[index].state = .failed(error.localizedDescription)
                }
            }
        } catch is CancellationError { return } catch {
            guard loadId == currentLoadId, !Task.isCancelled else { return }
            listingState = .failed(error.localizedDescription)
        }
    }

    private func updateUnreadMangas(_ change: ProgressService.Change) {
        let mangaIds: Set<String>
        let isUnread: Bool
        switch change { case .upserted(let records):
            mangaIds = Set(records.filter { $0.pluginId == share.id }.map(\.mangaId))
            isUnread = false
            case .deleted(let keys):
                mangaIds = Set(keys.filter { $0.pluginId == share.id }.map(\.mangaId))
                isUnread = true
        }
        guard !mangaIds.isEmpty else { return }

        for index in items.indices {
            guard let manga = items[index].manga, mangaIds.contains(manga.id) else { continue }
            items[index].state = .ready(manga, isUnread: isUnread)
        }
    }

    // MARK: - File views

    private func bookView(_ item: FileItem, fileType: String) -> some View {
        let content = bookContent(item, fileType: fileType)

        return Group {
            if isSelecting && viewMode == .grid {
                Button {
                    if !selectedPaths.insert(item.id).inserted { selectedPaths.remove(item.id) }
                } label: {
                    content
                }
                .disabled(isBusy)
            } else if !isSelecting, let manga = item.manga {
                NavigationLink(
                    destination: MangaDetailsScreen(plugin: share, manga: manga.toManga()) {
                        isDownloadsFolderPresented = true
                    }
                ) { content }
            } else {
                content
            }
        }
    }

    private func bookContent(_ item: FileItem, fileType: String) -> some View {
        Group {
            if viewMode == .grid {
                VStack(spacing: 8) {
                    selectableThumbnail(for: item.entity) {
                        bookThumbnail(item, fileType: fileType)
                    }
                    .modifier(bookContextMenu(for: item))

                    gridTitle(item.displayName)
                }
                .help(item.errorMessage ?? "")
            } else {
                bookListView(item, fileType: fileType).modifier(bookContextMenu(for: item))
            }
        }
        .contentShape(Rectangle())
    }

    private func bookListView(_ item: FileItem, fileType: String) -> some View {
        HStack(spacing: 16) {
            listThumbnail {
                bookThumbnail(item, fileType: fileType, cornerRadius: 6, showsUnreadTag: false)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayName).lineLimit(2)

                HStack(spacing: 8) {
                    Text(item.entity.name).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(fileType.uppercased()).smallTagStyle()
                }
                .font(.subheadline).foregroundStyle(.secondary)

                if let errorMessage = item.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").font(.caption)
                        .foregroundStyle(.orange).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8).contentShape(Rectangle())
    }

    @ViewBuilder private func bookThumbnail(
        _ item: FileItem, fileType: String, cornerRadius: CGFloat? = nil,
        showsUnreadTag: Bool = true
    ) -> some View {
        if let manga = item.manga {
            mangaThumbnail(
                manga: manga, isUnread: item.isUnread, cornerRadius: cornerRadius,
                showsUnreadTag: showsUnreadTag)
        } else {
            documentThumbnail(fileType: fileType, state: item.state)
        }
    }

    private func directoryGridView(entity: Entity) -> some View {
        VStack(spacing: 8) {
            thumbnailView { folderIcon }

            gridTitle(entity.displayName)
        }
    }

    private func directoryListView(entity: Entity) -> some View {
        HStack(spacing: 16) {
            listThumbnail { folderIcon }

            VStack(alignment: .leading, spacing: 4) { Text(entity.displayName).lineLimit(2) }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8).contentShape(Rectangle())
    }

    private var folderIcon: some View {
        Image("FolderIcon").resizable().scaledToFit()
            .overlay {
                Image("FolderIcon").renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(color ?? .accentColor).blendMode(.hue)
            }
            .compositingGroup()
    }

    // MARK: - Thumbnails

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
        Text(title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private func listThumbnail<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Color.clear.frame(width: 56, height: 72)
            .overlay { content().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private func selectionIndicator(for entity: Entity) -> some View {
        let isSelected = selectedPaths.contains(entity.path)

        return Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .foregroundStyle(isSelected ? Color.accentColor : Color(uiColor: .tertiaryLabel))
            .background(.background, in: Circle())
            .overlay { if isSelected { Circle().strokeBorder(.white) } }
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

    private func documentThumbnail(fileType: String, state: FileItem.ParseState) -> some View {
        let hasError = if case .failed = state { true } else { false }

        return ZStack(alignment: .bottomLeading) {
            Image("DocumentIcon").resizable().scaledToFill().clipped()

            switch state { case .failed:
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                    .padding(12).background(.regularMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .parsing(let progress):
                    ProgressView(value: progress).progressViewStyle(.circular).padding(12)
                        .background(.regularMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                default: EmptyView()
            }

            Text(fileType.uppercased()).font(.caption2).fontWeight(.semibold)
                .foregroundStyle(hasError ? Color.orange : Color.primary).padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(12)
        }
    }
}
