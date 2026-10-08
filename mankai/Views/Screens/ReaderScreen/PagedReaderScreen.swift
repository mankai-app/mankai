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

    var body: some View {
        positionedContent.background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }

    @ViewBuilder private var positionedContent: some View {
        if availability != .available {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if orientation == .vertical {
            content.frame(
                maxWidth: .infinity, maxHeight: .infinity, alignment: placeAtTop ? .top : .bottom)
        } else {
            content.frame(
                maxWidth: .infinity, maxHeight: 200,
                alignment: placeAtLeading ? .leading : .trailing
            )
            .padding()
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

private typealias OverscrollHostingController = UIHostingController<OverscrollView>

private final class PagedReaderViewController: UIViewController, UIPageViewControllerDataSource,
    UIPageViewControllerDelegate
{
    private var renderState: ReaderRenderState
    private var configuration: ReaderRenderConfiguration
    private var actions: ReaderRenderActions

    private var pageViewController: UIPageViewController!
    private let pageContainerScrollView = UIScrollView()
    private let leadingOverscrollView = UIView()
    private let trailingOverscrollView = UIView()
    private let leadingOverscrollController: UIHostingController<ReaderOverscrollIndicator>
    private let trailingOverscrollController: UIHostingController<ReaderOverscrollIndicator>
    private var overscrollPositionConstraints: [NSLayoutConstraint] = []
    private var overscrollLayoutOrientation: NavigationOrientation?
    private weak var pageTransitionScrollView: UIScrollView?
    private var pageTransitionScrollObservation: NSKeyValueObservation?
    private var pageTransitionRestingOffset: CGFloat = 0
    private var leadingOverscrollDistance: CGFloat = 0
    private var trailingOverscrollDistance: CGFloat = 0
    private var isTrackingPageTransitionOverscroll = false
    private var overscrollGestureGeneration = 0
    private var currentGroup = 0
    private var renderedRevision = -1
    private var renderedChapterID: String?
    private var lastAppliedNavigationGeneration = -1
    private var lastReportedViewportSize = CGSize.zero

    private var usesHorizontalRightToLeftNavigation: Bool {
        configuration.navigationOrientation == .horizontal
            && configuration.readingDirection == .rightToLeft
    }

    init(
        state: ReaderRenderState, configuration: ReaderRenderConfiguration,
        actions: ReaderRenderActions
    ) {
        renderState = state
        self.configuration = configuration
        self.actions = actions
        leadingOverscrollController = UIHostingController(
            rootView: ReaderOverscrollIndicator(
                progress: 0, direction: .up, step: .previous, availability: state.previousChapter))
        trailingOverscrollController = UIHostingController(
            rootView: ReaderOverscrollIndicator(
                progress: 0, direction: .down, step: .next, availability: state.nextChapter))
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

        applyCurrentState(force: true)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
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
        let chapterChanged = renderedChapterID != state.chapterID
        let contentChanged = renderedRevision != state.revision
        let presentationChanged =
            self.configuration.navigationOrientation != configuration.navigationOrientation
            || self.configuration.readingDirection != configuration.readingDirection
            || self.configuration.pageTransition != configuration.pageTransition

        renderState = state
        self.configuration = configuration
        self.actions = actions

        guard isViewLoaded else { return }

        if chapterChanged { currentGroup = 0 }

        if presentationChanged { recreatePageViewController() }

        if chapterChanged || contentChanged || presentationChanged {
            applyCurrentState(force: true)
        }

        if let command = state.navigationCommand,
            command.generation != lastAppliedNavigationGeneration
        {
            applyNavigationCommand(command)
        }

        updateScrollOverscrollIndicators()
    }

    private func applyCurrentState(force: Bool) {
        guard force || renderedRevision != renderState.revision else { return }
        renderedRevision = renderState.revision
        renderedChapterID = renderState.chapterID

        guard !renderState.groups.isEmpty else {
            let placeholder = UIViewController()
            placeholder.view.backgroundColor = .systemBackground
            pageViewController.setViewControllers(
                [placeholder], direction: .forward, animated: false)
            return
        }

        if renderState.urls.indices.contains(renderState.currentPage) {
            let currentURL = renderState.urls[renderState.currentPage]
            if let groupIndex = renderState.groups.firstIndex(where: { $0.contains(currentURL) }) {
                currentGroup = groupIndex
            }
        }
        currentGroup = min(max(currentGroup, 0), renderState.groups.count - 1)

        if let visiblePage = pageViewController.viewControllers?.first
            as? PageContentViewController, visiblePage.pageIndex == currentGroup,
            visiblePage.urls == renderState.groups[currentGroup].urls
        {
            visiblePage.apply(
                images: images(for: renderState.groups[currentGroup]),
                readingDirection: configuration.readingDirection)
        } else {
            showGroup(currentGroup, direction: .forward, animated: false)
        }
    }

    private func createPageViewController() {
        let orientation: UIPageViewController.NavigationOrientation =
            configuration.navigationOrientation == .vertical ? .vertical : .horizontal
        let transitionStyle: UIPageViewController.TransitionStyle =
            configuration.pageTransition == .pageCurl ? .pageCurl : .scroll
        let spineLocation: UIPageViewController.SpineLocation =
            usesHorizontalRightToLeftNavigation ? .max : .min
        let options: [UIPageViewController.OptionsKey: Any]? =
            transitionStyle == .pageCurl
            ? [.spineLocation: NSNumber(value: spineLocation.rawValue)] : nil
        pageViewController = UIPageViewController(
            transitionStyle: transitionStyle, navigationOrientation: orientation, options: options)
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
            NSLayoutConstraint.activate([
                pageViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
                pageViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                pageViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                pageViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        pageViewController.didMove(toParent: self)
        // Use the reader's tap handler so page curl respects navigation settings.
        for case let tapGesture as UITapGestureRecognizer in pageViewController.gestureRecognizers {
            tapGesture.isEnabled = false
        }
    }

    private func setupPageContainerScrollView() {
        pageContainerScrollView.translatesAutoresizingMaskIntoConstraints = false
        pageContainerScrollView.contentInsetAdjustmentBehavior = .never
        pageContainerScrollView.showsVerticalScrollIndicator = false
        pageContainerScrollView.showsHorizontalScrollIndicator = false
        leadingOverscrollView.translatesAutoresizingMaskIntoConstraints = false
        trailingOverscrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageContainerScrollView)
        pageContainerScrollView.addSubview(leadingOverscrollView)
        pageContainerScrollView.addSubview(trailingOverscrollView)
        NSLayoutConstraint.activate([
            pageContainerScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            pageContainerScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageContainerScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageContainerScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        leadingOverscrollController.sizingOptions = .intrinsicContentSize
        trailingOverscrollController.sizingOptions = .intrinsicContentSize
        leadingOverscrollController.safeAreaRegions = []
        trailingOverscrollController.safeAreaRegions = []

        let leadingIndicator = leadingOverscrollController.view!
        let trailingIndicator = trailingOverscrollController.view!
        leadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        trailingIndicator.translatesAutoresizingMaskIntoConstraints = false

        addChild(leadingOverscrollController)
        leadingOverscrollView.addSubview(leadingIndicator)
        leadingOverscrollController.didMove(toParent: self)

        addChild(trailingOverscrollController)
        trailingOverscrollView.addSubview(trailingIndicator)
        trailingOverscrollController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            leadingIndicator.topAnchor.constraint(equalTo: leadingOverscrollView.topAnchor),
            leadingIndicator.leadingAnchor.constraint(equalTo: leadingOverscrollView.leadingAnchor),
            leadingIndicator.trailingAnchor.constraint(
                equalTo: leadingOverscrollView.trailingAnchor),
            leadingIndicator.bottomAnchor.constraint(equalTo: leadingOverscrollView.bottomAnchor),

            trailingIndicator.topAnchor.constraint(equalTo: trailingOverscrollView.topAnchor),
            trailingIndicator.leadingAnchor.constraint(
                equalTo: trailingOverscrollView.leadingAnchor),
            trailingIndicator.trailingAnchor.constraint(
                equalTo: trailingOverscrollView.trailingAnchor),
            trailingIndicator.bottomAnchor.constraint(equalTo: trailingOverscrollView.bottomAnchor)
        ])
    }

    private func updateScrollOverscrollLayout() {
        guard
            overscrollPositionConstraints.isEmpty
                || overscrollLayoutOrientation != configuration.navigationOrientation
        else { return }

        overscrollLayoutOrientation = configuration.navigationOrientation
        NSLayoutConstraint.deactivate(overscrollPositionConstraints)

        if configuration.navigationOrientation == .vertical {
            overscrollPositionConstraints = [
                leadingOverscrollView.centerXAnchor.constraint(
                    equalTo: pageContainerScrollView.centerXAnchor),
                leadingOverscrollView.bottomAnchor.constraint(
                    equalTo: pageContainerScrollView.topAnchor,
                    constant: -READER_OVERSCROLL_MINIMUM_SPACING),
                leadingOverscrollView.widthAnchor.constraint(
                    equalTo: pageContainerScrollView.widthAnchor),
                trailingOverscrollView.centerXAnchor.constraint(
                    equalTo: pageContainerScrollView.centerXAnchor),
                trailingOverscrollView.topAnchor.constraint(
                    equalTo: pageContainerScrollView.bottomAnchor,
                    constant: READER_OVERSCROLL_MINIMUM_SPACING),
                trailingOverscrollView.widthAnchor.constraint(
                    equalTo: pageContainerScrollView.widthAnchor)
            ]
        } else {
            overscrollPositionConstraints = [
                leadingOverscrollView.centerYAnchor.constraint(
                    equalTo: pageContainerScrollView.centerYAnchor),
                leadingOverscrollView.trailingAnchor.constraint(
                    equalTo: pageContainerScrollView.leadingAnchor,
                    constant: -READER_OVERSCROLL_MINIMUM_SPACING),
                leadingOverscrollView.heightAnchor.constraint(
                    equalTo: pageContainerScrollView.heightAnchor),
                trailingOverscrollView.centerYAnchor.constraint(
                    equalTo: pageContainerScrollView.centerYAnchor),
                trailingOverscrollView.leadingAnchor.constraint(
                    equalTo: pageContainerScrollView.trailingAnchor,
                    constant: READER_OVERSCROLL_MINIMUM_SPACING),
                trailingOverscrollView.heightAnchor.constraint(
                    equalTo: pageContainerScrollView.heightAnchor)
            ]
        }

        NSLayoutConstraint.activate(overscrollPositionConstraints)
    }

    private func updateScrollOverscrollIndicators() {
        guard configuration.pageTransition == .scroll else {
            leadingOverscrollView.isHidden = true
            trailingOverscrollView.isHidden = true
            return
        }

        let leadingStep: ReaderStep = usesHorizontalRightToLeftNavigation ? .next : .previous
        let trailingStep: ReaderStep = usesHorizontalRightToLeftNavigation ? .previous : .next
        let leadingAvailability =
            leadingStep == .previous ? renderState.previousChapter : renderState.nextChapter
        let trailingAvailability =
            trailingStep == .previous ? renderState.previousChapter : renderState.nextChapter

        let hasGroups = !renderState.groups.isEmpty
        let isAtFirstGroup = hasGroups && currentGroup == 0
        let isAtLastGroup = hasGroups && currentGroup == renderState.groups.count - 1
        let leadingIsAtBoundary =
            usesHorizontalRightToLeftNavigation ? isAtLastGroup : isAtFirstGroup
        let trailingIsAtBoundary =
            usesHorizontalRightToLeftNavigation ? isAtFirstGroup : isAtLastGroup

        let leadingProgress =
            leadingIsAtBoundary
            ? readerOverscrollProgress(
                leadingOverscrollDistance, spacing: READER_OVERSCROLL_MINIMUM_SPACING) : 0
        let trailingProgress =
            trailingIsAtBoundary
            ? readerOverscrollProgress(
                trailingOverscrollDistance, spacing: READER_OVERSCROLL_MINIMUM_SPACING) : 0

        leadingOverscrollView.isHidden = !leadingIsAtBoundary
        trailingOverscrollView.isHidden = !trailingIsAtBoundary
        if configuration.navigationOrientation == .vertical {
            leadingOverscrollView.transform = CGAffineTransform(
                translationX: 0, y: leadingIsAtBoundary ? leadingOverscrollDistance : 0)
            trailingOverscrollView.transform = CGAffineTransform(
                translationX: 0, y: trailingIsAtBoundary ? -trailingOverscrollDistance : 0)
        } else {
            leadingOverscrollView.transform = CGAffineTransform(
                translationX: leadingIsAtBoundary ? leadingOverscrollDistance : 0, y: 0)
            trailingOverscrollView.transform = CGAffineTransform(
                translationX: trailingIsAtBoundary ? -trailingOverscrollDistance : 0, y: 0)
        }
        leadingOverscrollController.rootView = ReaderOverscrollIndicator(
            progress: Double(leadingProgress),
            direction: configuration.navigationOrientation == .vertical ? .up : .left,
            step: leadingStep, availability: leadingAvailability)
        trailingOverscrollController.rootView = ReaderOverscrollIndicator(
            progress: Double(trailingProgress),
            direction: configuration.navigationOrientation == .vertical ? .down : .right,
            step: trailingStep, availability: trailingAvailability)
    }

    private func setupPageTransitionOverscrollTracking() {
        pageTransitionScrollObservation = nil
        guard configuration.pageTransition == .scroll,
            let transitionScrollView = pageViewController.view.subviews
                .compactMap({ $0 as? UIScrollView }).first
        else { return }

        pageTransitionScrollView = transitionScrollView
        transitionScrollView.panGestureRecognizer.addTarget(
            self, action: #selector(handlePageTransitionPan(_:)))
        pageTransitionScrollObservation = transitionScrollView.observe(
            \.contentOffset, options: [.new]
        ) { [weak self] scrollView, _ in
            Task { @MainActor in self?.updateOverscrollDistances(from: scrollView) }
        }
    }

    private func tearDownPageTransitionOverscrollTracking() {
        overscrollGestureGeneration += 1
        pageTransitionScrollObservation = nil
        pageTransitionScrollView?.panGestureRecognizer
            .removeTarget(self, action: #selector(handlePageTransitionPan(_:)))
        pageTransitionScrollView = nil
        isTrackingPageTransitionOverscroll = false
        leadingOverscrollDistance = 0
        trailingOverscrollDistance = 0
    }

    private func resetPageTransitionOverscroll(after delay: TimeInterval = 0) {
        overscrollGestureGeneration += 1
        let generation = overscrollGestureGeneration

        if delay == 0 {
            isTrackingPageTransitionOverscroll = false
            leadingOverscrollDistance = 0
            trailingOverscrollDistance = 0
            updateScrollOverscrollIndicators()
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, generation == overscrollGestureGeneration else { return }
            isTrackingPageTransitionOverscroll = false
            leadingOverscrollDistance = 0
            trailingOverscrollDistance = 0
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
            leadingOverscrollDistance = 0
            trailingOverscrollDistance = 0
            updateScrollOverscrollIndicators()
            case .changed: updateOverscrollDistances(from: transitionScrollView)
            case .ended:
                updateOverscrollDistances(from: transitionScrollView)

                let requestedStep: ReaderStep?
                if readerOverscrollProgress(
                    leadingOverscrollDistance, spacing: READER_OVERSCROLL_MINIMUM_SPACING) >= 1
                {
                    requestedStep = usesHorizontalRightToLeftNavigation ? .next : .previous
                } else if readerOverscrollProgress(
                    trailingOverscrollDistance, spacing: READER_OVERSCROLL_MINIMUM_SPACING) >= 1
                {
                    requestedStep = usesHorizontalRightToLeftNavigation ? .previous : .next
                } else {
                    requestedStep = nil
                }

                if let requestedStep {
                    let isAtBoundary =
                        requestedStep == .previous
                        ? currentGroup == 0 : currentGroup == renderState.groups.count - 1
                    let availability =
                        requestedStep == .previous
                        ? renderState.previousChapter : renderState.nextChapter
                    if !renderState.groups.isEmpty, isAtBoundary, availability == .available {
                        actions.requestChapterStep(requestedStep)
                    }
                }

                resetPageTransitionOverscroll(after: 0.5)
            case .cancelled, .failed: resetPageTransitionOverscroll(after: 0.5)
            default: break
        }
    }

    private func updateOverscrollDistances(from scrollView: UIScrollView) {
        guard isTrackingPageTransitionOverscroll, scrollView === pageTransitionScrollView else {
            return
        }

        let currentOffset =
            configuration.navigationOrientation == .vertical
            ? scrollView.contentOffset.y : scrollView.contentOffset.x
        let offsetDelta = currentOffset - pageTransitionRestingOffset
        leadingOverscrollDistance = max(-offsetDelta, 0)
        trailingOverscrollDistance = max(offsetDelta, 0)
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

        if location.x < width / 3 {
            if usesHorizontalRightToLeftNavigation,
                configuration.tapNavigationBehavior == .followReadingDirection
            {
                actions.requestGroupStep(.next)
            } else {
                actions.requestGroupStep(.previous)
            }
        } else if location.x > width * 2 / 3 {
            if usesHorizontalRightToLeftNavigation,
                configuration.tapNavigationBehavior == .followReadingDirection
            {
                actions.requestGroupStep(.previous)
            } else {
                actions.requestGroupStep(.next)
            }
        } else {
            actions.toggleChrome()
        }
    }

    private func applyNavigationCommand(_ command: ReaderNavigationCommand) {
        guard
            let targetGroup = renderState.groups.firstIndex(where: {
                $0.contains(command.targetURL)
            })
        else { return }

        let direction: UIPageViewController.NavigationDirection
        if usesHorizontalRightToLeftNavigation {
            direction = targetGroup > currentGroup ? .reverse : .forward
        } else {
            direction = targetGroup > currentGroup ? .forward : .reverse
        }

        currentGroup = targetGroup
        showGroup(targetGroup, direction: direction, animated: command.animated)
        lastAppliedNavigationGeneration = command.generation
    }

    private func showGroup(
        _ groupIndex: Int, direction: UIPageViewController.NavigationDirection, animated: Bool
    ) {
        guard renderState.groups.indices.contains(groupIndex) else { return }
        let page = makePageContentViewController(for: groupIndex)
        pageViewController.setViewControllers([page], direction: direction, animated: animated)
        resetPageTransitionOverscroll()
    }

    private func makePageContentViewController(for groupIndex: Int) -> PageContentViewController {
        guard renderState.groups.indices.contains(groupIndex) else {
            return PageContentViewController(
                pageIndex: 0, urls: [], images: [:],
                readingDirection: configuration.readingDirection)
        }
        let group = renderState.groups[groupIndex]
        return PageContentViewController(
            pageIndex: groupIndex, urls: group.urls, images: images(for: group),
            readingDirection: configuration.readingDirection)
    }

    private func images(for group: ReaderGroup) -> [String: ReaderImageState] {
        Dictionary(
            uniqueKeysWithValues: group.urls.map { url in (url, renderState.images[url] ?? .loading)
            })
    }

    private func makeOverscrollViewController(step: ReaderStep) -> UIViewController {
        UIHostingController(
            rootView: OverscrollView(
                step: step, orientation: configuration.navigationOrientation,
                readingDirection: configuration.readingDirection,
                pageTransition: configuration.pageTransition,
                availability: step == .previous
                    ? renderState.previousChapter : renderState.nextChapter))
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
        guard !(viewController is OverscrollHostingController),
            let content = viewController as? PageContentViewController
        else { return nil }

        let delta: Int
        if configuration.navigationOrientation == .vertical {
            delta = before ? -1 : 1
        } else if usesHorizontalRightToLeftNavigation {
            delta = before ? 1 : -1
        } else {
            delta = before ? -1 : 1
        }

        let newIndex = content.pageIndex + delta
        if newIndex < 0 {
            guard configuration.pageTransition != .scroll else { return nil }
            return makeOverscrollViewController(step: .previous)
        }
        if newIndex >= renderState.groups.count {
            guard configuration.pageTransition != .scroll else { return nil }
            return makeOverscrollViewController(step: .next)
        }
        return makePageContentViewController(for: newIndex)
    }

    func pageViewController(
        _: UIPageViewController, didFinishAnimating _: Bool,
        previousViewControllers _: [UIViewController], transitionCompleted completed: Bool
    ) {
        guard completed, let visibleController = pageViewController.viewControllers?.first else {
            return
        }

        if let overscroll = visibleController as? OverscrollHostingController {
            let availability =
                overscroll.rootView.step == .previous
                ? renderState.previousChapter : renderState.nextChapter
            guard availability == .available else { return }
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

private final class PageContentViewController: UIViewController, UIScrollViewDelegate {
    let pageIndex: Int
    let urls: [String]
    private var images: [String: ReaderImageState]
    private var readingDirection: ReadingDirection

    private let scrollView = UIScrollView()
    private let contentStackView = UIStackView()
    private var contentCenterXConstraint: NSLayoutConstraint!
    private var imageViews: [String: UIImageView] = [:]
    private var imageWidthConstraints: [String: NSLayoutConstraint] = [:]
    private var loadingIndicators: [String: UIActivityIndicatorView] = [:]
    private var errorIcons: [String: UIImageView] = [:]
    private var imageSubscriptions: [String: AnyCancellable] = [:]

    init(
        pageIndex: Int, urls: [String], images: [String: ReaderImageState],
        readingDirection: ReadingDirection
    ) {
        self.pageIndex = pageIndex
        self.urls = urls
        self.images = images
        self.readingDirection = readingDirection
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
        updateContent()
    }

    func apply(images: [String: ReaderImageState], readingDirection: ReadingDirection) {
        self.images = images
        self.readingDirection = readingDirection
        guard isViewLoaded else { return }
        updateContent()
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 3
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        contentStackView.axis = .horizontal
        contentStackView.distribution = .fill
        contentStackView.spacing = 0
        scrollView.addSubview(contentStackView)

        contentCenterXConstraint = contentStackView.centerXAnchor.constraint(
            equalTo: scrollView.centerXAnchor)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentStackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentCenterXConstraint,
            contentStackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])

        let orderedURLs = readingDirection == .rightToLeft ? Array(urls.reversed()) : urls
        for url in orderedURLs {
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFit
            imageViews[url] = imageView
            container.addSubview(imageView)

            let loadingIndicator = UIActivityIndicatorView(style: .large)
            loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
            loadingIndicator.hidesWhenStopped = true
            loadingIndicators[url] = loadingIndicator
            container.addSubview(loadingIndicator)

            let errorIconName: String
            if #available(iOS 18.0, *) {
                errorIconName = "photo.badge.exclamationmark"
            } else {
                errorIconName = "exclamationmark.circle.fill"
            }
            let errorIcon = UIImageView(image: UIImage(systemName: errorIconName))
            errorIcon.translatesAutoresizingMaskIntoConstraints = false
            errorIcon.tintColor = .secondaryLabel
            errorIcon.contentMode = .scaleAspectFit
            errorIcon.isHidden = true
            errorIcons[url] = errorIcon
            container.addSubview(errorIcon)

            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                loadingIndicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                loadingIndicator.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                errorIcon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                errorIcon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                errorIcon.widthAnchor.constraint(equalToConstant: 48),
                errorIcon.heightAnchor.constraint(equalToConstant: 48)
            ])

            let widthConstraint = container.widthAnchor.constraint(equalToConstant: 1)
            widthConstraint.isActive = true
            imageWidthConstraints[url] = widthConstraint
            contentStackView.addArrangedSubview(container)
        }
    }

    private func updateContent() {
        guard !urls.isEmpty else { return }
        var ratios: [String: CGFloat] = [:]
        var totalRatio: CGFloat = 0

        for url in urls {
            if case .success(let image) = images[url] {
                let ratio = image.size.width / image.size.height
                ratios[url] = ratio
                totalRatio += ratio
            }
        }

        let safeAreaFrame = view.safeAreaLayoutGuide.layoutFrame
        contentCenterXConstraint.constant = safeAreaFrame.midX - view.bounds.midX
        let availableHeight = max(view.bounds.height, 1)
        let availableWidth = max(safeAreaFrame.width, 1)

        for url in urls {
            guard let imageView = imageViews[url], let loadingIndicator = loadingIndicators[url],
                let errorIcon = errorIcons[url], let widthConstraint = imageWidthConstraints[url]
            else { continue }

            switch images[url] ?? .loading { case .success(let image):
                if imageSubscriptions[url] == nil { observe(image, for: url) }
                imageView.image = image.image
                imageView.isHidden = false
                loadingIndicator.stopAnimating()
                errorIcon.isHidden = true
                let ratio = image.size.width / image.size.height
                var imageWidth = availableHeight * ratio
                if totalRatio > 0, availableHeight * totalRatio > availableWidth {
                    imageWidth = ratio / totalRatio * availableWidth
                }
                widthConstraint.constant = imageWidth
                case .failed:
                    imageView.isHidden = true
                    loadingIndicator.stopAnimating()
                    errorIcon.isHidden = false
                    widthConstraint.constant = availableWidth / CGFloat(urls.count)
                case .loading:
                    imageView.isHidden = true
                    loadingIndicator.startAnimating()
                    errorIcon.isHidden = true
                    widthConstraint.constant = availableWidth / CGFloat(urls.count)
            }
        }
    }

    private func observe(_ image: AppImage, for url: String) {
        imageSubscriptions[url] = image.$image.receive(on: DispatchQueue.main)
            .sink { [weak self] processedImage in
                guard let self else { return }
                imageViews[url]?.image = processedImage
                updateContent()
            }
    }

    func viewForZooming(in _: UIScrollView) -> UIView? { contentStackView }
}

private struct PagedReaderViewControllerWrapper: UIViewControllerRepresentable {
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

struct PagedReaderScreen: View {
    let state: ReaderRenderState
    let configuration: ReaderRenderConfiguration
    let actions: ReaderRenderActions

    var body: some View {
        PagedReaderViewControllerWrapper(
            state: state, configuration: configuration, actions: actions)
    }
}
