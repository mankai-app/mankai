//
//  PagedReaderScreen.swift
//  mankai
//
//  Created by Travis XU on 7/2/2026.
//

import Combine
import SwiftUI
import UIKit

private struct OverscrollView: View {
    let step: ReaderStep
    let orientation: NavigationOrientation
    let readingDirection: ReadingDirection
    let pageTransition: PageTransition
    let availability: ReaderChapterAvailability
    var showsContent = true

    var body: some View {
        positionedContent.opacity(showsContent ? 1 : 0)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }

    @ViewBuilder private var positionedContent: some View {
        if availability != .available {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if orientation == .vertical {
            content.frame(
                maxWidth: .infinity, maxHeight: .infinity, alignment: placeAtTop ? .top : .bottom)
        } else {
            content.frame(
                maxWidth: .infinity, maxHeight: .infinity,
                alignment: placeAtLeading ? .leading : .trailing)
        }
    }

    private var content: some View {
        VStack(spacing: 16) {
            Image(systemName: imageName).resizable().scaledToFit().frame(width: 48, height: 48)
            Text(message).multilineTextAlignment(.center)
        }
        .foregroundStyle(Color(uiColor: .secondaryLabel))
    }

    private var placeAtLeading: Bool {
        let placeAtLeading = (readingDirection == .rightToLeft) == (step == .previous)
        return pageTransition == .pageCurl ? !placeAtLeading : placeAtLeading
    }

    private var placeAtTop: Bool {
        let placeAtTop = step == .next
        return pageTransition == .pageCurl ? !placeAtTop : placeAtTop
    }

    private var imageName: String {
        switch availability { case .unavailable: return "xmark" case .locked: return "lock.fill"
            case .available:
                if orientation == .vertical {
                    return step == .previous ? "chevron.up" : "chevron.down"
                } else if readingDirection == .rightToLeft {
                    return step == .previous ? "chevron.right" : "chevron.left"
                } else {
                    return step == .previous ? "chevron.left" : "chevron.right"
                }
        }
    }

    private var message: String {
        switch availability { case .unavailable:
            return step == .previous
                ? String(localized: "noPreviousChapter") : String(localized: "noNextChapter")
            case .locked:
                return step == .previous
                    ? String(localized: "previousChapterIsLocked")
                    : String(localized: "nextChapterIsLocked")
            case .available:
                return step == .previous
                    ? String(localized: "turnToLoadPreviousChapter")
                    : String(localized: "turnToLoadNextChapter")
        }
    }
}

@MainActor private protocol ReaderPagePositioned { var pagePosition: Int { get } }

private struct ReaderPageViewport: Equatable {
    let bounds: CGRect
    let contentInsets: UIEdgeInsets
}

private final class OverscrollHostingController: UIHostingController<OverscrollView>,
    ReaderPagePositioned
{
    let pagePosition: Int

    init(pagePosition: Int, rootView: OverscrollView) {
        self.pagePosition = pagePosition
        super.init(rootView: rootView)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PagedReaderViewController: UIViewController, UIPageViewControllerDataSource,
    UIPageViewControllerDelegate
{
    private var renderState: ReaderRenderState
    private var configuration: ReaderRenderConfiguration
    private var actions: ReaderRenderActions

    private var pageViewController: UIPageViewController!
    private let contentPages = NSHashTable<PageContentViewController>.weakObjects()
    private let pageContainerScrollView = UIScrollView()
    private let overscrollIndicators = [
        ScrollOverscrollIndicatorController(isLeading: true),
        ScrollOverscrollIndicatorController(isLeading: false)
    ]
    private var overscrollPositionConstraints: [NSLayoutConstraint] = []
    private var overscrollLayoutOrientation: NavigationOrientation?
    private weak var pageTransitionScrollView: UIScrollView?
    private var pageTransitionScrollObservation: NSKeyValueObservation?
    private var pageTransitionRestingOffset: CGFloat = 0
    private var overscrollOffset: CGFloat = 0
    private var isTrackingPageTransitionOverscroll = false
    private var overscrollGestureGeneration = 0
    private var currentGroup = 0
    private var lastAppliedNavigationGeneration = -1
    private var lastReportedViewportSize = CGSize.zero

    private var pageViewport: ReaderPageViewport {
        ReaderPageViewport(bounds: view.bounds, contentInsets: configuration.contentSafeAreaInsets)
    }

    private var usesHorizontalRightToLeftNavigation: Bool {
        configuration.navigationOrientation == .horizontal
            && configuration.readingDirection == .rightToLeft
    }

    private var usesNativeDoublePage: Bool {
        configuration.pageTransition == .pageCurl
            && configuration.navigationOrientation == .horizontal
            && (configuration.defaultGroupSize == 2
                || renderState.groups.contains(where: { $0.urls.count == 2 }))
    }

    private var pagesPerGroup: Int { usesNativeDoublePage ? 2 : 1 }

    init(
        state: ReaderRenderState, configuration: ReaderRenderConfiguration,
        actions: ReaderRenderActions
    ) {
        renderState = state
        self.configuration = configuration
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupPageContainerScrollView()
        createPageViewController()

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(tapGesture)

        applyCurrentState()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updatePageViewports()
        if configuration.pageTransition == .scroll { updateScrollOverscrollLayout() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let viewportSize = view.bounds.size
        if viewportSize != lastReportedViewportSize, viewportSize.width > 0, viewportSize.height > 0
        {
            lastReportedViewportSize = viewportSize
            actions.viewportDidChange(viewportSize)
        }
    }

    func apply(
        state: ReaderRenderState, configuration: ReaderRenderConfiguration,
        actions: ReaderRenderActions
    ) {
        let chapterChanged = renderState.chapterID != state.chapterID
        let contentChanged = renderState.revision != state.revision
        let groupsChanged = renderState.groups != state.groups
        let contentInsetsChanged =
            self.configuration.contentSafeAreaInsets != configuration.contentSafeAreaInsets
        let presentationChanged =
            self.configuration.navigationOrientation != configuration.navigationOrientation
            || self.configuration.readingDirection != configuration.readingDirection
            || self.configuration.pageTransition != configuration.pageTransition
            || self.configuration.defaultGroupSize != configuration.defaultGroupSize

        renderState = state
        self.configuration = configuration
        self.actions = actions

        guard isViewLoaded else { return }

        if chapterChanged { currentGroup = 0 }

        if presentationChanged || groupsChanged { recreatePageViewController() }

        if chapterChanged || contentChanged || presentationChanged || groupsChanged {
            applyCurrentState(
                updateVisibleGroup: chapterChanged || presentationChanged || groupsChanged)
        }

        if contentInsetsChanged { updatePageViewports() }

        if let command = state.navigationCommand,
            command.generation != lastAppliedNavigationGeneration
        {
            applyNavigationCommand(command)
        }

        updateScrollOverscrollIndicators()
    }

    private func updatePageViewports() {
        let viewport = pageViewport
        for page in contentPages.allObjects { page.setViewport(viewport) }
    }

    private func applyCurrentState(updateVisibleGroup: Bool = true) {
        guard !renderState.groups.isEmpty else {
            let placeholders = (0..<pagesPerGroup)
                .map { _ in
                    let placeholder = UIViewController()
                    placeholder.view.backgroundColor = .systemBackground
                    return placeholder
                }
            pageViewController.setViewControllers(
                placeholders, direction: .forward, animated: false)
            return
        }

        if renderState.urls.indices.contains(renderState.currentPage) {
            let currentURL = renderState.urls[renderState.currentPage]
            if let groupIndex = renderState.groups.firstIndex(where: { $0.contains(currentURL) }) {
                currentGroup = groupIndex
            }
        }
        currentGroup = min(max(currentGroup, 0), renderState.groups.count - 1)

        // Prefetched pages retain their image snapshots until explicitly refreshed.
        for page in contentPages.allObjects {
            guard renderState.groups.indices.contains(page.pageIndex),
                page.urls == renderState.groups[page.pageIndex].urls
            else { continue }

            page.apply(images: images(for: renderState.groups[page.pageIndex]))
        }

        if updateVisibleGroup, !isShowingGroup(currentGroup) {
            showGroup(currentGroup, direction: .forward, animated: false)
        }
    }

    private func createPageViewController() {
        let orientation: UIPageViewController.NavigationOrientation =
            configuration.navigationOrientation == .vertical ? .vertical : .horizontal
        let transitionStyle: UIPageViewController.TransitionStyle =
            configuration.pageTransition == .pageCurl ? .pageCurl : .scroll
        let spineLocation: UIPageViewController.SpineLocation =
            usesNativeDoublePage ? .mid : (usesHorizontalRightToLeftNavigation ? .max : .min)
        let options: [UIPageViewController.OptionsKey: Any]? =
            transitionStyle == .pageCurl
            ? [.spineLocation: NSNumber(value: spineLocation.rawValue)] : nil
        pageViewController = UIPageViewController(
            transitionStyle: transitionStyle, navigationOrientation: orientation, options: options)
        if transitionStyle == .pageCurl { pageViewController.isDoubleSided = usesNativeDoublePage }
        pageViewController.dataSource = self
        pageViewController.delegate = self
        addChild(pageViewController)
        pageViewController.view.translatesAutoresizingMaskIntoConstraints = false

        if configuration.pageTransition == .scroll {
            pageContainerScrollView.isHidden = false
            pageContainerScrollView.setContentOffset(.zero, animated: false)
            pageContainerScrollView.addSubview(pageViewController.view)
            NSLayoutConstraint.activate([
                pageViewController.view.topAnchor.constraint(
                    equalTo: pageContainerScrollView.contentLayoutGuide.topAnchor),
                pageViewController.view.leadingAnchor.constraint(
                    equalTo: pageContainerScrollView.contentLayoutGuide.leadingAnchor),
                pageViewController.view.trailingAnchor.constraint(
                    equalTo: pageContainerScrollView.contentLayoutGuide.trailingAnchor),
                pageViewController.view.bottomAnchor.constraint(
                    equalTo: pageContainerScrollView.contentLayoutGuide.bottomAnchor),
                pageViewController.view.widthAnchor.constraint(
                    equalTo: pageContainerScrollView.frameLayoutGuide.widthAnchor),
                pageViewController.view.heightAnchor.constraint(
                    equalTo: pageContainerScrollView.frameLayoutGuide.heightAnchor)
            ])
            updateScrollOverscrollLayout()
            setupPageTransitionOverscrollTracking()
            updateScrollOverscrollIndicators()
        } else {
            pageContainerScrollView.isHidden = true
            view.addSubview(pageViewController.view)
            pageViewController.view.pinEdges(to: view)
        }
        pageViewController.didMove(toParent: self)
        // Use the reader's tap handler so page curl respects navigation settings.
        for case let tapGesture as UITapGestureRecognizer in pageViewController.gestureRecognizers {
            tapGesture.isEnabled = false
        }
    }

    private func setupPageContainerScrollView() {
        pageContainerScrollView.contentInsetAdjustmentBehavior = .never
        pageContainerScrollView.showsVerticalScrollIndicator = false
        pageContainerScrollView.showsHorizontalScrollIndicator = false
        hideReaderScrollEdgeEffects(pageContainerScrollView)
        view.addSubview(pageContainerScrollView)
        pageContainerScrollView.pinEdges(to: view)

        for indicator in overscrollIndicators {
            addChild(indicator)
            indicator.view.translatesAutoresizingMaskIntoConstraints = false
            pageContainerScrollView.addSubview(indicator.view)
            indicator.didMove(toParent: self)
        }
    }

    private func updateScrollOverscrollLayout() {
        guard overscrollLayoutOrientation != configuration.navigationOrientation else { return }
        overscrollLayoutOrientation = configuration.navigationOrientation
        NSLayoutConstraint.deactivate(overscrollPositionConstraints)
        overscrollPositionConstraints = overscrollIndicators.flatMap {
            $0.positionConstraints(
                in: pageContainerScrollView, orientation: configuration.navigationOrientation)
        }
        NSLayoutConstraint.activate(overscrollPositionConstraints)
    }

    private func chapterAvailability(for step: ReaderStep) -> ReaderChapterAvailability {
        step == .previous ? renderState.previousChapter : renderState.nextChapter
    }

    private func step(for indicator: ScrollOverscrollIndicatorController) -> ReaderStep {
        indicator.isLeading != usesHorizontalRightToLeftNavigation ? .previous : .next
    }

    private func updateScrollOverscrollIndicators() {
        for indicator in overscrollIndicators {
            guard configuration.pageTransition == .scroll else {
                indicator.view.isHidden = true
                continue
            }
            let step = step(for: indicator)
            let boundaryGroup = step == .previous ? 0 : renderState.groups.count - 1
            indicator.update(
                offset: overscrollOffset, orientation: configuration.navigationOrientation,
                step: step,
                isAtBoundary: !renderState.groups.isEmpty && currentGroup == boundaryGroup,
                availability: chapterAvailability(for: step))
        }
    }

    private func setupPageTransitionOverscrollTracking() {
        pageTransitionScrollObservation = nil
        guard configuration.pageTransition == .scroll,
            let transitionScrollView = pageViewController.view.subviews
                .compactMap({ $0 as? UIScrollView }).first
        else { return }

        pageTransitionScrollView = transitionScrollView
        hideReaderScrollEdgeEffects(transitionScrollView)
        transitionScrollView.panGestureRecognizer.addTarget(
            self, action: #selector(handlePageTransitionPan(_:)))
        pageTransitionScrollObservation = transitionScrollView.observe(
            \.contentOffset, options: [.new]
        ) { [weak self] scrollView, _ in
            Task { @MainActor in self?.updateOverscrollOffset(from: scrollView) }
        }
    }

    private func tearDownPageTransitionOverscrollTracking() {
        pageTransitionScrollObservation = nil
        pageTransitionScrollView?.panGestureRecognizer
            .removeTarget(self, action: #selector(handlePageTransitionPan(_:)))
        pageTransitionScrollView = nil
        resetPageTransitionOverscroll()
    }

    private func resetPageTransitionOverscroll(after delay: TimeInterval = 0) {
        overscrollGestureGeneration += 1
        if delay > 0 {
            let generation = overscrollGestureGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, generation == overscrollGestureGeneration else { return }
                resetPageTransitionOverscroll()
            }
        } else {
            isTrackingPageTransitionOverscroll = false
            overscrollOffset = 0
            updateScrollOverscrollIndicators()
        }
    }

    @objc private func handlePageTransitionPan(_ gesture: UIPanGestureRecognizer) {
        guard let transitionScrollView = pageTransitionScrollView else { return }

        switch gesture.state { case .began:
            overscrollGestureGeneration += 1
            isTrackingPageTransitionOverscroll = true
            pageTransitionRestingOffset =
                configuration.navigationOrientation == .vertical
                ? transitionScrollView.contentOffset.y : transitionScrollView.contentOffset.x
            overscrollOffset = 0
            updateScrollOverscrollIndicators()
            case .changed: updateOverscrollOffset(from: transitionScrollView)
            case .ended:
                updateOverscrollOffset(from: transitionScrollView)

                if let indicator = overscrollIndicators.first(where: { $0.progress >= 1 }) {
                    let requestedStep = step(for: indicator)
                    if chapterAvailability(for: requestedStep) == .available {
                        actions.requestChapterStep(requestedStep)
                    }
                }

                resetPageTransitionOverscroll(after: 0.5)
            case .cancelled, .failed: resetPageTransitionOverscroll(after: 0.5)
            default: break
        }
    }

    private func updateOverscrollOffset(from scrollView: UIScrollView) {
        guard isTrackingPageTransitionOverscroll, scrollView === pageTransitionScrollView else {
            return
        }

        let currentOffset =
            configuration.navigationOrientation == .vertical
            ? scrollView.contentOffset.y : scrollView.contentOffset.x
        overscrollOffset = currentOffset - pageTransitionRestingOffset
        updateScrollOverscrollIndicators()
    }

    private func recreatePageViewController() {
        tearDownPageTransitionOverscrollTracking()
        pageViewController.willMove(toParent: nil)
        pageViewController.view.removeFromSuperview()
        pageViewController.removeFromParent()
        createPageViewController()
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: view)
        let width = view.bounds.width

        guard configuration.tapNavigation else {
            actions.toggleChrome()
            return
        }

        let isLeading = location.x < width / 3
        guard isLeading || location.x > width * 2 / 3 else {
            actions.toggleChrome()
            return
        }

        let followsRightToLeft =
            usesHorizontalRightToLeftNavigation
            && configuration.tapNavigationBehavior == .followReadingDirection
        actions.requestGroupStep(isLeading != followsRightToLeft ? .previous : .next)
    }

    private func applyNavigationCommand(_ command: ReaderNavigationCommand) {
        guard
            let targetGroup = renderState.groups.firstIndex(where: {
                $0.contains(command.targetURL)
            })
        else { return }

        let movesForward = (targetGroup > currentGroup) != usesHorizontalRightToLeftNavigation
        let direction: UIPageViewController.NavigationDirection = movesForward ? .forward : .reverse

        currentGroup = targetGroup
        if !isShowingGroup(targetGroup) {
            showGroup(targetGroup, direction: direction, animated: command.animated)
        }
        lastAppliedNavigationGeneration = command.generation
    }

    private func showGroup(
        _ groupIndex: Int, direction: UIPageViewController.NavigationDirection, animated: Bool
    ) {
        guard renderState.groups.indices.contains(groupIndex) else { return }
        let pages = (0..<pagesPerGroup)
            .map {
                makePageContentViewController(
                    for: groupIndex, spreadPageIndex: usesNativeDoublePage ? $0 : nil)
            }
        let orderedPages = usesHorizontalRightToLeftNavigation ? Array(pages.reversed()) : pages
        pageViewController.setViewControllers(
            orderedPages, direction: direction, animated: animated)
        resetPageTransitionOverscroll()
    }

    private func isShowingGroup(_ groupIndex: Int) -> Bool {
        let pages =
            pageViewController.viewControllers?.compactMap { $0 as? PageContentViewController }
            ?? []
        return pages.count == pagesPerGroup
            && pages.allSatisfy {
                $0.pageIndex == groupIndex && $0.urls == renderState.groups[groupIndex].urls
            }
    }

    private func makePageContentViewController(for groupIndex: Int, spreadPageIndex: Int? = nil)
        -> PageContentViewController
    {
        let group = renderState.groups[groupIndex]
        let page = PageContentViewController(
            pageIndex: groupIndex, urls: group.urls, images: images(for: group),
            readingDirection: configuration.readingDirection, viewport: pageViewport,
            spreadPageIndex: spreadPageIndex)
        page.onSingleImageViewportChange = { [weak self] source in
            guard let visiblePages = self?.pageViewController.viewControllers else { return }
            for case let otherPage as PageContentViewController in visiblePages
            where otherPage !== source { otherPage.synchronizeSingleImageViewport(with: source) }
        }
        contentPages.add(page)
        return page
    }

    private func images(for group: ReaderGroup) -> [String: ReaderImageState] {
        Dictionary(
            uniqueKeysWithValues: group.urls.map { url in (url, renderState.images[url] ?? .loading)
            })
    }

    private func makeOverscrollViewController(step: ReaderStep, pagePosition: Int)
        -> UIViewController
    {
        // The next chapter hint belongs on the second leaf in reading order.
        let isFirstLeaf = pagePosition.isMultiple(of: 2)
        let showsContent = !usesNativeDoublePage || (step == .previous ? isFirstLeaf : !isFirstLeaf)
        return OverscrollHostingController(
            pagePosition: pagePosition,
            rootView: OverscrollView(
                step: step, orientation: configuration.navigationOrientation,
                readingDirection: configuration.readingDirection,
                pageTransition: configuration.pageTransition,
                availability: chapterAvailability(for: step), showsContent: showsContent))
    }

    func pageViewController(
        _: UIPageViewController, viewControllerBefore viewController: UIViewController
    ) -> UIViewController? { adjacentViewController(to: viewController, before: true) }

    func pageViewController(
        _: UIPageViewController, viewControllerAfter viewController: UIViewController
    ) -> UIViewController? { adjacentViewController(to: viewController, before: false) }

    private func adjacentViewController(to viewController: UIViewController, before: Bool)
        -> UIViewController?
    {
        guard let page = viewController as? ReaderPagePositioned else { return nil }

        let delta = before != usesHorizontalRightToLeftNavigation ? -1 : 1

        let newPosition = page.pagePosition + delta
        let contentPageCount = renderState.groups.count * pagesPerGroup
        if newPosition < 0 {
            guard configuration.pageTransition != .scroll else { return nil }
            guard newPosition >= -pagesPerGroup else { return nil }
            return makeOverscrollViewController(step: .previous, pagePosition: newPosition)
        }
        if newPosition >= contentPageCount {
            guard configuration.pageTransition != .scroll else { return nil }
            guard newPosition < contentPageCount + pagesPerGroup else { return nil }
            return makeOverscrollViewController(step: .next, pagePosition: newPosition)
        }
        return makePageContentViewController(
            for: newPosition / pagesPerGroup,
            spreadPageIndex: usesNativeDoublePage ? newPosition % pagesPerGroup : nil)
    }

    func pageViewController(
        _: UIPageViewController, didFinishAnimating _: Bool,
        previousViewControllers _: [UIViewController], transitionCompleted completed: Bool
    ) {
        guard completed, let visibleController = pageViewController.viewControllers?.first else {
            return
        }

        if let overscroll = visibleController as? OverscrollHostingController {
            guard chapterAvailability(for: overscroll.rootView.step) == .available else { return }
            actions.requestChapterStep(overscroll.rootView.step)
            return
        }

        guard let page = visibleController as? PageContentViewController,
            renderState.groups.indices.contains(page.pageIndex),
            let firstURL = renderState.groups[page.pageIndex].urls.first,
            let rawPage = renderState.urls.firstIndex(of: firstURL)
        else { return }

        currentGroup = page.pageIndex
        resetPageTransitionOverscroll()
        actions.pageDidChange(rawPage)
    }
}

private final class PageImageView: UIView {
    private let imageView = UIImageView()
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let errorIcon = UIImageView()
    private weak var observedImage: AppImage?
    private var imageSubscription: AnyCancellable?
    lazy var widthConstraint = widthAnchor.constraint(equalToConstant: 1)
    var onImageChange: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        imageView.pinEdges(to: self)

        loadingIndicator.hidesWhenStopped = true
        if #available(iOS 18.0, *) {
            errorIcon.image = UIImage(systemName: "photo.badge.exclamationmark")
        } else {
            errorIcon.image = UIImage(systemName: "exclamationmark.circle.fill")
        }
        errorIcon.tintColor = .secondaryLabel
        errorIcon.contentMode = .scaleAspectFit
        errorIcon.isHidden = true

        let overlays: [UIView] = [loadingIndicator, errorIcon]
        for overlay in overlays {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.centerXAnchor.constraint(equalTo: centerXAnchor),
                overlay.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            errorIcon.widthAnchor.constraint(equalToConstant: 48),
            errorIcon.heightAnchor.constraint(equalToConstant: 48), widthConstraint
        ])
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ state: ReaderImageState) {
        let image: AppImage?
        imageView.isHidden = true
        loadingIndicator.stopAnimating()
        errorIcon.isHidden = true
        switch state { case .success(let loadedImage):
            image = loadedImage
            imageView.image = loadedImage.image
            imageView.isHidden = false
            case .failed:
                image = nil
                errorIcon.isHidden = false
            case .loading:
                image = nil
                loadingIndicator.startAnimating()
        }

        guard observedImage !== image else { return }
        observedImage = image
        imageSubscription = nil
        if let image {
            imageSubscription = image.$image.receive(on: DispatchQueue.main)
                .sink { [weak self] processedImage in
                    self?.imageView.image = processedImage
                    self?.onImageChange?()
                }
        }
    }
}

private final class PageContentViewController: UIViewController, UIScrollViewDelegate,
    ReaderPagePositioned
{
    let pageIndex: Int
    let urls: [String]
    private let spreadPageIndex: Int?
    private var viewport: ReaderPageViewport
    private var images: [String: ReaderImageState]
    private let readingDirection: ReadingDirection
    private var isSynchronizingViewport = false
    var onSingleImageViewportChange: ((PageContentViewController) -> Void)?

    private let scrollView = UIScrollView()
    private let contentStackView = UIStackView()
    private var contentCenterXConstraint: NSLayoutConstraint!
    private var contentTopConstraint: NSLayoutConstraint!
    private var contentBottomConstraint: NSLayoutConstraint!
    private var contentHeightConstraint: NSLayoutConstraint!
    private var imageViews: [String: PageImageView] = [:]

    var pagePosition: Int {
        guard let spreadPageIndex else { return pageIndex }
        return pageIndex * 2 + spreadPageIndex
    }

    private var displayedURLs: [String] {
        guard let spreadPageIndex, urls.count == 2 else { return urls }
        return [urls[spreadPageIndex]]
    }

    private var spansSpread: Bool {
        guard spreadPageIndex != nil, urls.count == 1, let url = urls.first,
            case .success(let image) = images[url]
        else { return false }
        return image.size.width > image.size.height
    }

    init(
        pageIndex: Int, urls: [String], images: [String: ReaderImageState],
        readingDirection: ReadingDirection, viewport: ReaderPageViewport,
        spreadPageIndex: Int? = nil
    ) {
        self.pageIndex = pageIndex
        self.urls = urls
        self.images = images
        self.readingDirection = readingDirection
        self.viewport = viewport
        self.spreadPageIndex = spreadPageIndex
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateContent()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayout()
    }

    func apply(images: [String: ReaderImageState]) {
        self.images = images
        guard isViewLoaded else { return }
        updateContent()
    }

    func setViewport(_ viewport: ReaderPageViewport) {
        guard self.viewport != viewport else { return }
        self.viewport = viewport
        viewIfLoaded?.setNeedsLayout()
    }

    func synchronizeSingleImageViewport(with source: PageContentViewController) {
        guard isViewLoaded, source.isViewLoaded, spansSpread, source.spansSpread,
            urls == source.urls, pageIndex == source.pageIndex, let spreadPageIndex,
            let sourcePageIndex = source.spreadPageIndex, spreadPageIndex != sourcePageIndex
        else { return }

        isSynchronizingViewport = true
        defer { isSynchronizingViewport = false }

        let sourceFrame = source.contentStackView.frame
        let sourceOffset = source.scrollView.contentOffset
        scrollView.setZoomScale(source.scrollView.zoomScale, animated: false)
        scrollView.layoutIfNeeded()

        let pageDelta = spreadPageIndex - sourcePageIndex
        let physicalPageDelta = readingDirection == .rightToLeft ? -pageDelta : pageDelta
        let originDelta = CGFloat(physicalPageDelta) * viewport.bounds.width / 2
        scrollView.setContentOffset(
            CGPoint(
                x: contentStackView.frame.minX - sourceFrame.minX + sourceOffset.x + originDelta,
                y: contentStackView.frame.minY - sourceFrame.minY + sourceOffset.y), animated: false
        )
    }

    func scrollViewDidZoom(_: UIScrollView) { reportSingleImageViewportChange() }

    func scrollViewDidScroll(_: UIScrollView) { reportSingleImageViewportChange() }

    private func reportSingleImageViewportChange() {
        guard !isSynchronizingViewport, spansSpread else { return }
        onSingleImageViewportChange?(self)
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 3
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        hideReaderScrollEdgeEffects(scrollView)
        view.addSubview(scrollView)
        scrollView.pinEdges(to: view)

        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        contentStackView.axis = .horizontal
        contentStackView.distribution = .fill
        contentStackView.spacing = 0
        scrollView.addSubview(contentStackView)

        contentCenterXConstraint = contentStackView.centerXAnchor.constraint(
            equalTo: scrollView.centerXAnchor)
        contentTopConstraint = contentStackView.topAnchor.constraint(equalTo: scrollView.topAnchor)
        contentBottomConstraint = contentStackView.bottomAnchor.constraint(
            equalTo: scrollView.bottomAnchor)
        contentHeightConstraint = contentStackView.heightAnchor.constraint(
            equalTo: scrollView.heightAnchor)
        NSLayoutConstraint.activate([
            contentTopConstraint, contentBottomConstraint, contentCenterXConstraint,
            contentHeightConstraint
        ])

        let orderedURLs =
            readingDirection == .rightToLeft ? Array(displayedURLs.reversed()) : displayedURLs
        for url in orderedURLs {
            let imageView = PageImageView()
            imageView.onImageChange = { [weak self] in self?.updateLayout() }
            imageViews[url] = imageView
            contentStackView.addArrangedSubview(imageView)
        }
    }

    private func updateContent() {
        for (url, imageView) in imageViews { imageView.apply(images[url] ?? .loading) }
        updateLayout()
    }

    private func updateLayout() {
        guard !urls.isEmpty else { return }
        scrollView.isHidden = spreadPageIndex == 1 && urls.count == 1 && !spansSpread
        var ratios: [String: CGFloat] = [:]
        var totalRatio: CGFloat = 0

        for url in urls {
            let ratio: CGFloat
            if case .success(let image) = images[url] {
                ratio = image.size.width / image.size.height
            } else {
                ratio = 1
            }
            ratios[url] = ratio
            totalRatio += ratio
        }

        // Prefetched leaves can have transient safe areas while UIKit turns the page.
        let viewportBounds = viewport.bounds
        let contentFrame = viewportBounds.inset(by: viewport.contentInsets)
        let availableHeight = max(contentFrame.height, 1)
        let availableWidth = max(contentFrame.width, 1)

        let imageHeight: CGFloat
        let centerX: CGFloat
        let isRightToLeft = readingDirection == .rightToLeft
        var pageOriginX: CGFloat = 0
        if let spreadPageIndex {
            let physicalPageIndex = isRightToLeft ? 1 - spreadPageIndex : spreadPageIndex
            pageOriginX = CGFloat(physicalPageIndex) * viewportBounds.width / 2
        }

        if let spreadPageIndex, urls.count <= 2, !spansSpread {
            // Fit pages to a shared height, each against its side of the native spine.
            let fittingHeights = urls.enumerated()
                .map { index, url in
                    let isRightPage = (index == 0) == isRightToLeft
                    let pageWidth = max(
                        isRightPage
                            ? contentFrame.maxX - viewportBounds.midX
                            : viewportBounds.midX - contentFrame.minX, 1)
                    return pageWidth / ratios[url, default: 1]
                }
            imageHeight = min(availableHeight, fittingHeights.min() ?? availableHeight)
            // A single portrait stays on the first leaf, the other leaf is hidden.
            let imageIndex = min(spreadPageIndex, urls.count - 1)
            let imageWidth = imageHeight * ratios[urls[imageIndex], default: 1]
            let isRightPage = (imageIndex == 0) == isRightToLeft
            centerX = viewportBounds.midX + (isRightPage ? imageWidth / 2 : -imageWidth / 2)
        } else {
            imageHeight = min(availableHeight, availableWidth / totalRatio)
            let imageWidth = imageHeight * totalRatio
            // Each native leaf clips its half of a wide image spanning the spread.
            centerX = min(
                max(viewportBounds.midX, contentFrame.minX + imageWidth / 2),
                contentFrame.maxX - imageWidth / 2)
        }

        let centerY = min(
            max(viewportBounds.midY, contentFrame.minY + imageHeight / 2),
            contentFrame.maxY - imageHeight / 2)
        contentCenterXConstraint.constant = centerX - pageOriginX - view.bounds.midX
        contentTopConstraint.constant = centerY - view.bounds.minY - availableHeight / 2
        contentBottomConstraint.constant = centerY - view.bounds.maxY + availableHeight / 2
        contentHeightConstraint.constant = availableHeight - view.bounds.height

        for (url, imageView) in imageViews {
            imageView.widthConstraint.constant = imageHeight * ratios[url, default: 1]
        }
    }

    func viewForZooming(in _: UIScrollView) -> UIView? { contentStackView }
}

struct PagedReaderScreen: UIViewControllerRepresentable {
    let state: ReaderRenderState
    let configuration: ReaderRenderConfiguration
    let actions: ReaderRenderActions

    func makeUIViewController(context _: Context) -> PagedReaderViewController {
        PagedReaderViewController(state: state, configuration: configuration, actions: actions)
    }

    func updateUIViewController(_ viewController: PagedReaderViewController, context _: Context) {
        viewController.apply(state: state, configuration: configuration, actions: actions)
    }
}
