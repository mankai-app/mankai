//
//  ReaderScreen.swift
//  mankai
//
//  Created by Travis XU on 7/2/2026.
//

import SwiftUI
import UIKit

private struct ReaderChapterLoadKey: Hashable {
    let chapterID: String?
    let retryGeneration: Int
    let slideReadingDirection: ReadingDirection
}

private struct ReaderAdjacencyKey: Hashable {
    let chapterLoadKey: ReaderChapterLoadKey
    let imagesSettled: Bool
    let readingDirection: ReadingDirection
    let enabled: Bool
}

@MainActor private struct ReaderAdjacencyPair {
    let firstURL: String
    let secondURL: String
    let leftImage: AppImage
    let rightImage: AppImage

    var key: String { ReaderGrouping.pairKey(firstURL, secondURL) }
}

private struct ReaderGroupingKey: Equatable {
    let readerType: ReaderType
    let imageLayout: ImageLayout
    let readingDirection: ReadingDirection
    let smartGrouping: Bool
    let sensitivity: Double
    let viewportWidth: Int
    let viewportHeight: Int
}

@MainActor private enum ReaderGrouping {
    static func defaultGroupSize(
        readingDirection: ReadingDirection, imageLayout: ImageLayout, viewportSize: CGSize
    ) -> Int {
        if readingDirection == .vertical { return 1 }

        switch imageLayout { case .auto: return viewportSize.width > viewportSize.height ? 2 : 1
            case .onePerRow: return 1
            case .twoPerRow: return 2
        }
    }

    static func makeGroups(
        urls: [String], images: [String: ReaderImageState], defaultGroupSize: Int,
        smartGrouping: Bool, smartGroupingSensitivity: Double, adjacencyScores: [String: Double]
    ) -> [ReaderGroup] {
        var groups: [ReaderGroup] = []
        var index = 0

        while index < urls.count {
            let url = urls[index]

            if isWide(url: url, images: images) {
                groups.append(ReaderGroup(urls: [url]))
                index += 1
                continue
            }

            if index + 1 < urls.count {
                let nextURL = urls[index + 1]
                if isSpread(
                    url, nextURL, smartGrouping: smartGrouping,
                    sensitivity: smartGroupingSensitivity, adjacencyScores: adjacencyScores)
                {
                    groups.append(ReaderGroup(urls: [url, nextURL]))
                    index += 2
                    continue
                }
            }

            var groupURLs: [String] = []
            var candidateIndex = index

            while candidateIndex < urls.count, groupURLs.count < defaultGroupSize {
                let candidateURL = urls[candidateIndex]
                if isWide(url: candidateURL, images: images) { break }

                if candidateIndex > index, candidateIndex + 1 < urls.count,
                    isSpread(
                        candidateURL, urls[candidateIndex + 1], smartGrouping: smartGrouping,
                        sensitivity: smartGroupingSensitivity, adjacencyScores: adjacencyScores)
                {
                    break
                }

                groupURLs.append(candidateURL)
                candidateIndex += 1
            }

            if groupURLs.isEmpty {
                groupURLs.append(url)
                candidateIndex = index + 1
            }

            groups.append(ReaderGroup(urls: groupURLs))
            index = candidateIndex
        }

        return groups
    }

    static func pairKey(_ firstURL: String, _ secondURL: String) -> String {
        "\(firstURL)|\(secondURL)"
    }

    private static func isWide(url: String, images: [String: ReaderImageState]) -> Bool {
        guard case .success(let image) = images[url] else { return false }
        return image.size.width > image.size.height
    }

    private static func isSpread(
        _ firstURL: String, _ secondURL: String, smartGrouping: Bool, sensitivity: Double,
        adjacencyScores: [String: Double]
    ) -> Bool {
        guard smartGrouping else { return false }
        return adjacencyScores[pairKey(firstURL, secondURL), default: 0] > (1 - sensitivity)
    }
}

private struct ReaderSourceCapabilityError: Error {}

private struct ReaderSavedPosition: Equatable {
    let chapterID: String
    let page: Int
}

private enum ReaderImageLoadResult: Sendable {
    case success(String, AppImage)
    case failed(String)
}

private struct ReaderLegacyTabBarModifier: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content } else { content.toolbar(.hidden, for: .tabBar) }
    }
}

private struct ReaderCoverSceneAccessoryModifier: ViewModifier {
    @Binding var isEnabled: Bool
    let coverURL: String?
    let plugin: Plugin

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.sceneAccessory {
                ExternalNonInteractiveAccessory(isEnabled: $isEnabled) {
                    MangaCoverView(coverUrl: coverURL, plugin: plugin, cornerRadius: 0)
                        .ignoresSafeArea()
                }
            }
        } else {
            content
        }
    }
}

private struct ReaderNavigationBarController: UIViewControllerRepresentable {
    let isNavigationBarHidden: Bool
    let onWillDisappear: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onWillDisappear: onWillDisappear) }

    func makeUIViewController(context: Context) -> Controller {
        Controller { context.coordinator.onWillDisappear() }
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        context.coordinator.onWillDisappear = onWillDisappear
        controller.setNavigationBarHidden(isNavigationBarHidden, animated: true)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator _: Coordinator) {
        controller.restoreNavigationBar()
        if #available(iOS 18.0, *) {
            controller.tabBarController?.setTabBarHidden(false, animated: true)
        }
    }

    final class Coordinator {
        var onWillDisappear: () -> Void

        init(onWillDisappear: @escaping () -> Void) { self.onWillDisappear = onWillDisappear }
    }

    final class Controller: UIViewController {
        private let showChrome: () -> Void
        private var shouldHideNavigationBar = false
        private var isAnimatingNavigationBar = false

        init(showChrome: @escaping () -> Void) {
            self.showChrome = showChrome
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable) required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            NotificationCenter.default.addObserver(
                self, selector: #selector(sceneDidBecomeActive(_:)),
                name: UIScene.didActivateNotification, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if #available(iOS 18.0, *) {
                tabBarController?.setTabBarHidden(true, animated: animated)
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyNavigationBarVisibility(animated: false)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard shouldHideNavigationBar, !isAnimatingNavigationBar else { return }
            applyNavigationBarVisibility(animated: false)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            shouldHideNavigationBar = false
            restoreNavigationBar(animated: animated)
            if #available(iOS 18.0, *) {
                tabBarController?.setTabBarHidden(false, animated: animated)
            }
            showChrome()
        }

        @objc private func sceneDidBecomeActive(_ notification: Notification) {
            guard let scene = notification.object as? UIScene,
                scene === viewIfLoaded?.window?.windowScene
            else { return }
            applyNavigationBarVisibility(animated: false)
        }

        func setNavigationBarHidden(_ isHidden: Bool, animated: Bool) {
            guard shouldHideNavigationBar != isHidden else { return }
            shouldHideNavigationBar = isHidden
            applyNavigationBarVisibility(animated: animated)
        }

        private func applyNavigationBarVisibility(animated: Bool) {
            guard let navigationBar = navigationController?.navigationBar else { return }

            // Use untransformed geometry so repeated updates preserve the hidden position.
            let bottomY = navigationBar.center.y + navigationBar.bounds.height / 2
            let transform =
                shouldHideNavigationBar
                ? CGAffineTransform(translationX: 0, y: -bottomY) : .identity

            updateNavigationBar(navigationBar, transform: transform, animated: animated)
        }

        func restoreNavigationBar(animated: Bool = false) {
            guard let navigationBar = navigationController?.navigationBar else { return }
            updateNavigationBar(navigationBar, transform: .identity, animated: animated)
        }

        private func updateNavigationBar(
            _ navigationBar: UINavigationBar, transform: CGAffineTransform, animated: Bool
        ) {
            let changes = { navigationBar.transform = transform }

            guard animated else {
                changes()
                return
            }

            isAnimatingNavigationBar = true
            UIView.animate(
                withDuration: 0.2, delay: 0,
                options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction],
                animations: changes
            ) { _ in self.isAnimatingNavigationBar = false }
        }
    }
}

struct ReaderScreen: View {
    let plugin: Plugin
    let manga: DetailedManga
    let downloadManga: DetailedManga?
    let chapterGroupIndex: Int
    let chapter: Chapter
    var initialPage: Int?

    @AppStorage(SettingsKey.readerType.rawValue) private var readerTypeRawValue: Int =
        SettingsDefaults.readerType.rawValue
    @AppStorage(SettingsKey.imageLayout.rawValue) private var imageLayoutRawValue: Int =
        SettingsDefaults.imageLayout.rawValue
    @AppStorage(SettingsKey.respectMangaReadingDirection.rawValue) private
        var respectMangaReadingDirection = SettingsDefaults.respectMangaReadingDirection
    @AppStorage(SettingsKey.smartGrouping.rawValue) private var smartGrouping = SettingsDefaults
        .smartGrouping
    @AppStorage(SettingsKey.smartGroupingSensitivity.rawValue) private
        var smartGroupingSensitivity = SettingsDefaults.smartGroupingSensitivity
    @AppStorage(SettingsKey.showCoverOnExternalDisplay.rawValue) private
        var showCoverOnExternalDisplay = SettingsDefaults.showCoverOnExternalDisplay
    /// Continuous Reader
    @AppStorage(SettingsKey.CR_readingDirection.rawValue) private var continuousDirectionRawValue =
        SettingsDefaults.CR_readingDirection.rawValue
    @AppStorage(SettingsKey.CR_tapNavigation.rawValue) private var continuousTapNavigation =
        SettingsDefaults.CR_tapNavigation
    @AppStorage(SettingsKey.CR_snapToPage.rawValue) private var continuousSnapToPage =
        SettingsDefaults.CR_snapToPage
    @AppStorage(SettingsKey.CR_softSnap.rawValue) private var continuousSoftSnap = SettingsDefaults
        .CR_softSnap

    /// Paged Reader
    @AppStorage(SettingsKey.PR_readingDirection.rawValue) private var pagedDirectionRawValue =
        SettingsDefaults.PR_readingDirection.rawValue
    @AppStorage(SettingsKey.PR_navigationOrientation.rawValue) private
        var pagedOrientationRawValue = SettingsDefaults.PR_navigationOrientation.rawValue
    @AppStorage(SettingsKey.PR_pageTransition.rawValue) private var pagedTransitionRawValue =
        SettingsDefaults.PR_pageTransition.rawValue
    @AppStorage(SettingsKey.PR_tapNavigation.rawValue) private var pagedTapNavigation =
        SettingsDefaults.PR_tapNavigation
    @AppStorage(SettingsKey.PR_tapNavigationBehavior.rawValue) private
        var pagedTapBehaviorRawValue = SettingsDefaults.PR_tapNavigationBehavior.rawValue

    @State private var currentChapterIndex: Int
    @State private var pendingInitialPage: Int?
    @State private var retryGeneration = 0
    @State private var loadPhase = ReaderLoadPhase.idle
    @State private var urls: [String] = []
    @State private var images: [String: ReaderImageState] = [:]
    @State private var imageLoadingFinished = false
    @State private var groups: [ReaderGroup] = []
    @State private var adjacencyScores: [String: Double] = [:]
    @State private var checkedPairs: Set<String> = []
    @State private var currentPage = 0
    @State private var contentRevision = 0
    @State private var navigationGeneration = 0
    @State private var navigationCommand: ReaderNavigationCommand?
    @State private var viewportSize: CGSize = .zero
    @State private var isChromeVisible = true
    @State private var isShowingChapters = false
    @State private var saveScheduled = false
    @State private var saveRequestGeneration = 0
    @State private var lastSavedPosition: ReaderSavedPosition?

    init(
        plugin: Plugin, manga: DetailedManga, downloadManga: DetailedManga?, chapterGroupIndex: Int,
        chapter: Chapter, initialPage: Int? = nil
    ) {
        self.plugin = plugin
        self.manga = manga
        self.downloadManga = downloadManga
        self.chapterGroupIndex = chapterGroupIndex
        self.chapter = chapter
        self.initialPage = initialPage

        let chapters =
            manga.chapters.indices.contains(chapterGroupIndex)
            ? manga.chapters[chapterGroupIndex].chapters : []
        _currentChapterIndex = State(
            initialValue: chapters.firstIndex(where: { $0.id == chapter.id }) ?? -1)
        _pendingInitialPage = State(initialValue: initialPage)
    }

    private var chapters: [Chapter] {
        guard manga.chapters.indices.contains(chapterGroupIndex) else { return [] }
        return manga.chapters[chapterGroupIndex].chapters
    }

    private var currentChapter: Chapter? {
        guard chapters.indices.contains(currentChapterIndex) else { return nil }
        return chapters[currentChapterIndex]
    }

    private var downloadedChapterIds: Set<String> {
        Set(
            downloadManga?.chapters
                .flatMap { group in group.chapters.filter { $0.locked != true }.map(\.id) } ?? [])
    }

    private func canRead(_ chapter: Chapter) -> Bool {
        downloadedChapterIds.contains(chapter.id)
            || (chapter.locked != true && plugin.supportsRemoteReading)
    }

    private var readerType: ReaderType {
        if respectMangaReadingDirection, manga.readingDirection == .vertical { return .continuous }
        return ReaderType(rawValue: readerTypeRawValue) ?? SettingsDefaults.readerType
    }

    private var readingDirection: ReadingDirection {
        if respectMangaReadingDirection, let direction = manga.readingDirection { return direction }

        switch readerType { case .continuous:
            return ReadingDirection(rawValue: continuousDirectionRawValue)
                ?? SettingsDefaults.CR_readingDirection
            case .paged:
                return ReadingDirection(rawValue: pagedDirectionRawValue)
                    ?? SettingsDefaults.PR_readingDirection
        }
    }

    private var imageLayout: ImageLayout {
        ImageLayout(rawValue: imageLayoutRawValue) ?? SettingsDefaults.imageLayout
    }

    private var pagedTapBehavior: TapBehavior {
        TapBehavior(rawValue: pagedTapBehaviorRawValue) ?? SettingsDefaults.PR_tapNavigationBehavior
    }

    private var pagedNavigationOrientation: NavigationOrientation {
        NavigationOrientation(rawValue: pagedOrientationRawValue)
            ?? SettingsDefaults.PR_navigationOrientation
    }

    private var pagedPageTransition: PageTransition {
        PageTransition(rawValue: pagedTransitionRawValue) ?? SettingsDefaults.PR_pageTransition
    }

    private var readerTypeSelection: Binding<ReaderType> {
        Binding(
            get: { readerType },
            set: { readerType in
                scheduleCurrentPageNavigationCommand()
                readerTypeRawValue = readerType.rawValue
            })
    }

    private var imageLayoutSelection: Binding<ImageLayout> {
        Binding(
            get: { imageLayout },
            set: { imageLayout in
                scheduleCurrentPageNavigationCommand()
                imageLayoutRawValue = imageLayout.rawValue
            })
    }

    private var readingDirectionSelection: Binding<ReadingDirection> {
        Binding(
            get: { readingDirection },
            set: { direction in
                scheduleCurrentPageNavigationCommand()
                pendingInitialPage = currentPage
                switch readerType { case .continuous:
                    continuousDirectionRawValue = direction.rawValue
                    case .paged: pagedDirectionRawValue = direction.rawValue
                }
            })
    }

    private var smartGroupingSelection: Binding<Bool> {
        Binding(
            get: { smartGrouping },
            set: { isEnabled in
                scheduleCurrentPageNavigationCommand()
                smartGrouping = isEnabled
            })
    }

    private var tapNavigationSelection: Binding<Bool> {
        Binding(
            get: { readerType == .continuous ? continuousTapNavigation : pagedTapNavigation },
            set: { isEnabled in
                switch readerType { case .continuous: continuousTapNavigation = isEnabled
                    case .paged: pagedTapNavigation = isEnabled
                }
            })
    }

    private var followReadingDirectionSelection: Binding<Bool> {
        Binding(
            get: { pagedTapBehavior == .followReadingDirection },
            set: { isEnabled in
                pagedTapBehaviorRawValue =
                    isEnabled
                    ? TapBehavior.followReadingDirection.rawValue
                    : TapBehavior.previousNext.rawValue
            })
    }

    private var navigationOrientationSelection: Binding<NavigationOrientation> {
        Binding(
            get: { pagedNavigationOrientation },
            set: { orientation in
                scheduleCurrentPageNavigationCommand()
                pagedOrientationRawValue = orientation.rawValue
            })
    }

    private var pageTransitionSelection: Binding<PageTransition> {
        Binding(
            get: { pagedPageTransition },
            set: { transition in
                scheduleCurrentPageNavigationCommand()
                pagedTransitionRawValue = transition.rawValue
            })
    }

    private var defaultGroupSize: Int {
        ReaderGrouping.defaultGroupSize(
            readingDirection: readingDirection, imageLayout: imageLayout, viewportSize: viewportSize
        )
    }

    private var renderConfiguration: ReaderRenderConfiguration {
        ReaderRenderConfiguration(
            readingDirection: readingDirection, defaultGroupSize: defaultGroupSize,

            tapNavigation: readerType == .continuous ? continuousTapNavigation : pagedTapNavigation,

            tapNavigationBehavior: pagedTapBehavior,
            navigationOrientation: pagedNavigationOrientation, pageTransition: pagedPageTransition,

            snapToPage: continuousSnapToPage, softSnap: continuousSoftSnap)
    }

    private var renderState: ReaderRenderState {
        ReaderRenderState(
            revision: contentRevision, chapterID: currentChapter?.id, urls: urls, images: images,
            groups: groups, currentPage: currentPage, navigationCommand: navigationCommand,
            previousChapter: previousChapterAvailability, nextChapter: nextChapterAvailability)
    }

    private var renderActions: ReaderRenderActions {
        ReaderRenderActions(
            pageDidChange: pageDidChange, requestGroupStep: stepGroup,
            requestChapterStep: stepChapter, toggleChrome: toggleChrome,
            viewportDidChange: updateViewportSize)
    }

    private var chapterLoadKey: ReaderChapterLoadKey {
        ReaderChapterLoadKey(
            chapterID: currentChapter?.id, retryGeneration: retryGeneration,
            slideReadingDirection: readingDirection)
    }

    private var adjacencyKey: ReaderAdjacencyKey {
        ReaderAdjacencyKey(
            chapterLoadKey: chapterLoadKey, imagesSettled: imageLoadingFinished,
            readingDirection: readingDirection,
            enabled: smartGrouping && readingDirection != .vertical)
    }

    private var groupingKey: ReaderGroupingKey {
        ReaderGroupingKey(
            readerType: readerType, imageLayout: imageLayout, readingDirection: readingDirection,
            smartGrouping: smartGrouping, sensitivity: smartGroupingSensitivity,
            viewportWidth: Int(viewportSize.width.rounded()),
            viewportHeight: Int(viewportSize.height.rounded()))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                renderer.ignoresSafeArea()

                LinearGradient(
                    colors: [Color(uiColor: .systemBackground).opacity(0.25), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: UIApplication.statusBarHeight ?? 0)
                .frame(maxHeight: .infinity, alignment: .top).ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

                loadOverlay

                if #available(iOS 26.0, *) {
                    GlassEffectContainer {
                        if isChromeVisible {
                            readerControls(bottomSafeAreaInset: proxy.safeAreaInsets.bottom)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .animation(.default, value: isChromeVisible)
                } else {
                    ZStack(alignment: .bottom) {
                        if isChromeVisible {
                            readerControls(bottomSafeAreaInset: proxy.safeAreaInsets.bottom)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .animation(.easeInOut(duration: 0.2), value: isChromeVisible)
                }
            }
            .ignoresSafeArea(edges: .bottom).onAppear { updateViewportSize(proxy.size) }
            .onChange(of: proxy.size) { _, size in updateViewportSize(size) }
        }
        .navigationTitle(currentChapter.map { $0.title ?? $0.id } ?? "")
        .navigationBarTitleDisplayMode(.inline).toolbarBackground(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { readerSettingsMenu } }
        .modifier(
            ReaderCoverSceneAccessoryModifier(
                isEnabled: $showCoverOnExternalDisplay,
                coverURL: manga.cover ?? downloadManga?.cover, plugin: plugin)
        )
        .modifier(ReaderLegacyTabBarModifier())
        .background {
            ReaderNavigationBarController(isNavigationBarHidden: !isChromeVisible) {
                isChromeVisible = true
            }
        }
        .sheet(isPresented: $isShowingChapters) {
            ChaptersModal(
                plugin: plugin, manga: manga, chapterGroupIndex: chapterGroupIndex,
                downloadChapters: downloadedChapterIds,
                canReadRemotely: plugin.supportsRemoteReading, allowEditing: false
            ) { selectedChapter, _, _ in
                selectChapter(selectedChapter)
                isShowingChapters = false
            }
        }
        .task(id: chapterLoadKey) { await loadChapter(for: chapterLoadKey) }
        .task(id: adjacencyKey) { await updateAdjacencyScores(for: adjacencyKey) }
        .task(id: saveRequestGeneration) { await performScheduledSave() }
        .onChange(of: groupingKey) { oldValue, _ in
            if oldValue.readingDirection != readingDirection {
                checkedPairs.removeAll()
                adjacencyScores.removeAll()
            }
            regroup(keepCurrentPageVisible: true)
        }
        .onDisappear { finishReading() }
    }

    private var readerSettingsMenu: some View {
        Menu {
            Picker(selection: readerTypeSelection) {
                Text(ReaderType.paged.localizedName).tag(ReaderType.paged)
                Text(ReaderType.continuous.localizedName).tag(ReaderType.continuous)
            } label: {
                Label("readerType", systemImage: "book.pages")
            }
            .disabled(respectMangaReadingDirection && manga.readingDirection == .vertical)

            Section("readerSettings") {
                Button {
                    readingDirectionSelection.wrappedValue =
                        readingDirection == .leftToRight ? .rightToLeft : .leftToRight
                } label: {
                    Label {
                        Text("reverseReadingDirection")
                    } icon: {
                        if #available(iOS 18.0, *) {
                            Image(
                                systemName: readingDirection == .rightToLeft
                                    ? "inset.filled.lefthalf.arrow.left.rectangle"
                                    : "inset.filled.righthalf.arrow.right.rectangle")
                        } else {
                            Image(
                                systemName: readingDirection == .rightToLeft
                                    ? "rectangle.lefthalf.inset.filled.arrow.left"
                                    : "rectangle.righthalf.inset.filled.arrow.right")
                        }
                    }
                    Text(readingDirection.localizedName)
                }
                .disabled(respectMangaReadingDirection && manga.readingDirection != nil)

                if readerType == .paged {
                    Button {
                        navigationOrientationSelection.wrappedValue =
                            navigationOrientationSelection.wrappedValue == .horizontal
                            ? .vertical : .horizontal
                    } label: {
                        Label(
                            "switchNavigationOrientation", systemImage: "rectangle.portrait.rotate")
                        Text(navigationOrientationSelection.wrappedValue.localizedName)
                    }

                    Picker(selection: pageTransitionSelection) {
                        Text(PageTransition.scroll.localizedName).tag(PageTransition.scroll)
                        Text(PageTransition.pageCurl.localizedName).tag(PageTransition.pageCurl)
                    } label: {
                        Label("pageTransition", systemImage: "book.pages")
                    }
                    .pickerStyle(.menu)
                }

                Toggle(isOn: tapNavigationSelection) {
                    Label("tapNavigation", systemImage: "hand.tap")
                }

                if readerType == .paged, pagedTapNavigation,
                    navigationOrientationSelection.wrappedValue == .horizontal
                {
                    Toggle(isOn: followReadingDirectionSelection) {
                        Label(
                            TapBehavior.followReadingDirection.localizedName,
                            systemImage: "arrow.left.arrow.right")
                    }
                }
            }

            Section("imageGrouping") {
                Picker(selection: imageLayoutSelection) {
                    Text(ImageLayout.auto.localizedName).tag(ImageLayout.auto)
                    Text(ImageLayout.onePerRow.localizedName).tag(ImageLayout.onePerRow)
                    Text(ImageLayout.twoPerRow.localizedName).tag(ImageLayout.twoPerRow)
                } label: {
                    Label("imageLayout", systemImage: "rectangle.grid.2x2")
                }
                .pickerStyle(.menu)

                Toggle(isOn: smartGroupingSelection) {
                    Label("smartGrouping", systemImage: "sparkles")
                }
            }
        } label: {
            Label("settings", systemImage: "gearshape")
        }
        .menuOrder(.fixed)
    }

    @ViewBuilder private var renderer: some View {
        switch readerType { case .continuous:
            ContinuousReaderScreen(
                state: renderState, configuration: renderConfiguration, actions: renderActions)
            case .paged:
                PagedReaderScreen(
                    state: renderState, configuration: renderConfiguration, actions: renderActions)
        }
    }

    @ViewBuilder private var loadOverlay: some View {
        switch loadPhase { case .idle, .loading: ProgressView().controlSize(.large) case .failed:
            Button {
                retryGeneration += 1
                loadPhase = .loading
            } label: {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 44))
                    Text("failedToLoadChapter")
                    Text("tapToRetry").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            case .ready: EmptyView()
        }
    }

    private func readerControls(bottomSafeAreaInset: CGFloat) -> some View {
        HStack {
            chapterButton(
                systemImage: "chevron.left.to.line", label: "previousChapter",
                enabled: previousChapterAvailability == .available
            ) { stepChapter(.previous) }

            readerSlider

            chapterButton(
                systemImage: "chevron.right.to.line", label: "nextChapter",
                enabled: nextChapterAvailability == .available
            ) { stepChapter(.next) }
        }
        .disabled(loadPhase != .ready).padding(.horizontal, 16)
        .padding(.bottom, max(8, bottomSafeAreaInset))
    }

    private var readerSlider: some View {
        let pageCount = max(urls.count, 1)
        let displayedPage = min(currentPage + 1, pageCount)

        return BooksSlider(
            value: Binding(
                get: { Double(displayedPage) },
                set: { requestPage(Int($0.rounded()) - 1, animated: false) }),
            bounds: 1...Double(pageCount), step: 1, canScrub: urls.count > 1,
            previewTitle: currentChapter.map { $0.title ?? $0.id },
            action: { isShowingChapters = true }
        )
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 420)
    }

    private func chapterButton(
        systemImage: String, label: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage).labelStyle(.iconOnly)
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain).adaptiveGlassBackground(in: Circle()).disabled(!enabled).zIndex(2)
    }

    private func chapterAvailability(at index: Int) -> ReaderChapterAvailability {
        guard chapters.indices.contains(index) else { return .unavailable }
        return canRead(chapters[index]) ? .available : .locked
    }

    private var previousChapterAvailability: ReaderChapterAvailability {
        chapterAvailability(at: currentChapterIndex - 1)
    }

    private var nextChapterAvailability: ReaderChapterAvailability {
        chapterAvailability(at: currentChapterIndex + 1)
    }

    private func canStepGroup(_ step: ReaderStep) -> Bool {
        guard let groupIndex = currentGroupIndex else { return false }
        switch step { case .previous: return groupIndex > 0 case .next:
            return groupIndex < groups.count - 1
        }
    }

    private var currentGroupIndex: Int? {
        guard urls.indices.contains(currentPage) else { return nil }
        return groups.firstIndex { $0.contains(urls[currentPage]) }
    }

    private func pageDidChange(_ page: Int) {
        guard urls.indices.contains(page) else { return }
        let chapterID = currentChapter?.id
        let pageURL = urls[page]

        Task { @MainActor in
            guard currentChapter?.id == chapterID, urls.indices.contains(page),
                urls[page] == pageURL, currentPage != page
            else { return }

            currentPage = page
            scheduleSave()
        }
    }

    private func stepGroup(_ step: ReaderStep) {
        guard let groupIndex = currentGroupIndex else { return }
        let targetIndex = step == .previous ? groupIndex - 1 : groupIndex + 1
        guard groups.indices.contains(targetIndex), let targetURL = groups[targetIndex].urls.first,
            let page = urls.firstIndex(of: targetURL)
        else { return }

        requestPage(page, animated: true)
    }

    private func requestPage(_ page: Int, animated: Bool) {
        guard urls.indices.contains(page) else { return }
        let selectedURL = urls[page]
        guard let group = groups.first(where: { $0.contains(selectedURL) }),
            let targetURL = group.urls.first, let targetPage = urls.firstIndex(of: targetURL)
        else { return }

        currentPage = targetPage
        navigationGeneration += 1
        navigationCommand = ReaderNavigationCommand(
            generation: navigationGeneration, targetURL: targetURL, animated: animated)
        scheduleSave()
    }

    private func scheduleCurrentPageNavigationCommand() {
        guard urls.indices.contains(currentPage) else { return }
        let targetURL = urls[currentPage]

        Task { @MainActor in
            guard let targetPage = urls.firstIndex(of: targetURL) else { return }

            currentPage = targetPage
            navigationGeneration += 1
            navigationCommand = ReaderNavigationCommand(
                generation: navigationGeneration, targetURL: targetURL, animated: false)
        }
    }

    private func stepChapter(_ step: ReaderStep) {
        let targetIndex = step == .previous ? currentChapterIndex - 1 : currentChapterIndex + 1
        guard chapterAvailability(at: targetIndex) == .available else { return }

        forceSaveCurrentPosition()
        currentChapterIndex = targetIndex
        pendingInitialPage = step == .previous ? -1 : 0
        loadPhase = .loading
    }

    private func selectChapter(_ selectedChapter: Chapter) {
        guard canRead(selectedChapter),
            let index = chapters.firstIndex(where: { $0.id == selectedChapter.id })
        else { return }

        forceSaveCurrentPosition()
        currentChapterIndex = index
        pendingInitialPage = 0
        loadPhase = .loading
    }

    private func toggleChrome() {
        if #available(iOS 26.0, *) {
            withAnimation { isChromeVisible.toggle() }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { isChromeVisible.toggle() }
        }
    }

    private func updateViewportSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, viewportSize != size else { return }
        viewportSize = size
    }

    @MainActor private func loadChapter(for key: ReaderChapterLoadKey) async {
        guard let chapter = currentChapter, chapter.id == key.chapterID, canRead(chapter) else {
            loadPhase = .failed
            return
        }

        loadPhase = .loading
        urls = []
        images = [:]
        imageLoadingFinished = false
        groups = []
        adjacencyScores = [:]
        checkedPairs = []
        currentPage = 0
        navigationCommand = nil
        contentRevision += 1

        do {
            let loadedURLs = try await chapterURLs(for: chapter)
            try Task.checkCancellation()
            guard chapterLoadKey == key, !loadedURLs.isEmpty else {
                if chapterLoadKey == key { loadPhase = .failed }
                return
            }

            urls = loadedURLs
            images = Dictionary(uniqueKeysWithValues: loadedURLs.map { ($0, .loading) })
            regroup()
            loadPhase = .ready

            let requestedPage: Int
            if pendingInitialPage == -1 {
                requestedPage = loadedURLs.count - 1
            } else if let pendingInitialPage {
                requestedPage = pendingInitialPage
            } else {
                requestedPage = 0
            }
            pendingInitialPage = nil
            requestPage(min(max(requestedPage, 0), loadedURLs.count - 1), animated: false)

            await withTaskGroup(of: ReaderImageLoadResult.self) { taskGroup in
                for url in loadedURLs { taskGroup.addTask { await loadImage(url: url) } }

                for await result in taskGroup {
                    guard !Task.isCancelled, chapterLoadKey == key else {
                        taskGroup.cancelAll()
                        return
                    }

                    switch result { case .success(let url, let image): images[url] = .success(image)
                        case .failed(let url): images[url] = .failed
                    }
                    regroup(keepCurrentPageVisible: true)
                }
            }

            guard !Task.isCancelled, chapterLoadKey == key else { return }
            imageLoadingFinished = true
        } catch is CancellationError { return } catch {
            guard chapterLoadKey == key else { return }
            Logger.ui.error("Failed to load chapter", error: error)
            loadPhase = .failed
        }
    }

    private func chapterURLs(for chapter: Chapter) async throws -> [String] {
        if let downloadManga {
            do {
                let downloadedURLs = try await DownloadPlugin.shared.getChapter(
                    manga: downloadManga, chapter: chapter)
                if !downloadedURLs.isEmpty { return downloadedURLs }
            } catch { Logger.ui.warning("Failed to load chapter from download") }
        }

        try Task.checkCancellation()
        guard plugin.supports(.chapter) else { throw ReaderSourceCapabilityError() }
        return try await plugin.getChapter(manga: manga, chapter: chapter)
    }

    private func loadImage(url: String) async -> ReaderImageLoadResult {
        for retry in 0...3 {
            do {
                let data: Data
                let isDownloaded =
                    (try? await DownloadPlugin.shared.isImageDownloaded(url)) ?? false
                try Task.checkCancellation()

                if isDownloaded {
                    data = try await DownloadPlugin.shared.getImage(url)
                } else {
                    guard plugin.supports(.image) else { throw ReaderSourceCapabilityError() }
                    data = try await plugin.getImage(url)
                }

                if let image = await AppImage.load(data: data) { return .success(url, image) }
            } catch is CancellationError { return .failed(url) } catch {
                if retry == 3 { Logger.ui.error("Failed to load reader image", error: error) }
            }

            guard retry < 3 else { break }
            do { try await Task.sleep(for: .seconds(1 << retry)) } catch { return .failed(url) }
        }

        return .failed(url)
    }

    @MainActor private func updateAdjacencyScores(for key: ReaderAdjacencyKey) async {
        guard key.enabled, key.imagesSettled, key.chapterLoadKey == chapterLoadKey else { return }

        let pairs = urls.indices.dropLast()
            .compactMap { index -> ReaderAdjacencyPair? in
                let firstURL = urls[index]
                let secondURL = urls[index + 1]
                guard !checkedPairs.contains(ReaderGrouping.pairKey(firstURL, secondURL)),
                    case .success(let firstImage) = images[firstURL],
                    case .success(let secondImage) = images[secondURL]
                else { return nil }

                let isRightToLeft = readingDirection == .rightToLeft
                return ReaderAdjacencyPair(
                    firstURL: firstURL, secondURL: secondURL,
                    leftImage: isRightToLeft ? secondImage : firstImage,
                    rightImage: isRightToLeft ? firstImage : secondImage)
            }

        Logger.smartGrouping.notice(
            "Starting adjacency pass with \(pairs.count) pending pairs for \(urls.count) pages")

        defer {
            for pair in pairs {
                pair.leftImage.releaseSlides()
                pair.rightImage.releaseSlides()
            }
        }

        var completedCount = 0

        for pair in pairs {
            do {
                guard let leftSlide = await pair.leftImage.takeSlide(.right),
                    let rightSlide = await pair.rightImage.takeSlide(.left)
                else {
                    Logger.smartGrouping.error(
                        "Missing generated image slide for adjacency pair \(pair.key)")
                    continue
                }

                let score = try await SmartGrouping.shared.predict(
                    leftSlide: leftSlide, rightSlide: rightSlide)

                guard !Task.isCancelled, adjacencyKey == key else {
                    Logger.smartGrouping.notice(
                        "Cancelled adjacency pass after \(completedCount) of \(pairs.count) pending pairs"
                    )
                    return
                }
                checkedPairs.insert(pair.key)
                adjacencyScores[pair.key] = score
                completedCount += 1
                regroup(keepCurrentPageVisible: true)
            } catch is CancellationError {
                Logger.smartGrouping.notice(
                    "Cancelled adjacency pass after \(completedCount) of \(pairs.count) pending pairs"
                )
                return
            } catch { Logger.ui.error("Adjacency check failed", error: error) }
        }

        Logger.smartGrouping.notice(
            "Finished adjacency pass with \(completedCount) predictions, \(checkedPairs.count) pairs checked"
        )
    }

    private func regroup(keepCurrentPageVisible: Bool = false) {
        let currentURL = urls.indices.contains(currentPage) ? urls[currentPage] : nil
        groups = ReaderGrouping.makeGroups(
            urls: urls, images: images, defaultGroupSize: defaultGroupSize,
            smartGrouping: smartGrouping && readingDirection != .vertical,
            smartGroupingSensitivity: smartGroupingSensitivity, adjacencyScores: adjacencyScores)
        contentRevision += 1

        if keepCurrentPageVisible, let currentURL, urls.contains(currentURL) {
            navigationGeneration += 1
            navigationCommand = ReaderNavigationCommand(
                generation: navigationGeneration, targetURL: currentURL, animated: false)
        }
    }

    private func scheduleSave() {
        guard currentChapter != nil, !saveScheduled else { return }
        saveScheduled = true
        saveRequestGeneration += 1
    }

    @MainActor private func performScheduledSave() async {
        guard saveScheduled else { return }
        do { try await Task.sleep(for: .seconds(3)) } catch { return }

        guard saveScheduled else { return }
        saveScheduled = false
        await persistCurrentPosition()
    }

    private func forceSaveCurrentPosition() {
        saveScheduled = false
        saveRequestGeneration += 1
        guard let chapter = currentChapter else { return }
        let page = currentPage
        Task { await persist(chapter: chapter, page: page) }
    }

    @MainActor private func persistCurrentPosition() async {
        guard let chapter = currentChapter else { return }
        await persist(chapter: chapter, page: currentPage)
    }

    @MainActor private func persist(chapter: Chapter, page: Int) async {
        let position = ReaderSavedPosition(chapterID: chapter.id, page: page)
        guard lastSavedPosition != position else { return }

        let progress = ProgressModel(
            mangaId: manga.id, pluginId: plugin.id, datetime: Date(), chapterId: chapter.id,
            chapterTitle: chapter.title, page: page, shouldSync: plugin.shouldSync)

        do {
            let mangaModel = try MangaSnapshotService.shared.makeSnapshot(
                for: manga.toManga(), pluginId: plugin.id)
            _ = try await ProgressService.shared.save(progress: progress, manga: mangaModel)
            lastSavedPosition = position
        } catch { Logger.ui.error("Failed to save reader position", error: error) }
    }

    private func finishReading() {
        saveScheduled = false
        saveRequestGeneration += 1
        guard let chapter = currentChapter else { return }
        let page = currentPage

        Task {
            await persist(chapter: chapter, page: page)
            try? await SyncService.shared.sync()
        }
    }
}
