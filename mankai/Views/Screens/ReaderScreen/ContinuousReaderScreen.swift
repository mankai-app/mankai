//
//  ContinuousReaderScreen.swift
//  mankai
//
//  Created by Travis XU on 30/6/2025.
//

import Combine
import SwiftUI
import UIKit

private let CONTINUOUS_LOADING_IMAGE_TAG = 1
private let CONTINUOUS_ERROR_IMAGE_TAG = 2

private struct ContinuousGroup: Equatable {
    let urls: [String]
    var y: CGFloat = 0
    var height: CGFloat = 0

    func contains(_ url: String) -> Bool { urls.contains(url) }
}

final class ContinuousReaderViewController: UIViewController, UIScrollViewDelegate {
    private var renderState: ReaderRenderState
    private var configuration: ReaderRenderConfiguration
    private var actions: ReaderRenderActions

    private var groups: [ContinuousGroup] = []
    private var currentPage = 0
    private var currentGroupIndex: Int?
    private var startY: CGFloat = 0
    private var navigationBarHeight: CGFloat?
    private var renderedRevision = -1
    private var renderedChapterID: String?
    private var lastAppliedNavigationGeneration = -1
    private var pendingNavigationCommand: ReaderNavigationCommand?
    private var animatedNavigationGeneration: Int?
    private var isNavigationCommandApplicationScheduled = false
    private var lastReportedViewportSize = CGSize.zero
    private var imageViews: [String: UIView] = [:]
    private var imageSubscriptions: [String: AnyCancellable] = [:]

    private var isResizing = false

    private var contentSafeAreaInsets: UIEdgeInsets {
        if navigationBarHeight == nil {
            navigationBarHeight = navigationController?.navigationBar.frame.height
        }
        return readerContentSafeAreaInsets(
            in: view, fullscreenDisplay: configuration.fullscreenDisplay,
            navigationBarHeight: navigationBarHeight ?? 0)
    }

    private var contentLayoutFrame: CGRect { view.bounds.inset(by: contentSafeAreaInsets) }

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let containerView = UIView()
    private let topOverscrollController = ScrollOverscrollIndicatorController(isLeading: true)
    private let bottomOverscrollController = ScrollOverscrollIndicatorController(isLeading: false)

    private var containerLeadingConstraint: NSLayoutConstraint!
    private var containerTopConstraint: NSLayoutConstraint!
    private var containerWidthConstraint: NSLayoutConstraint!
    private var containerHeightConstraint: NSLayoutConstraint!
    private var contentHeightConstraint: NSLayoutConstraint!

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
        setupUI()
        setupConstraints()

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        scrollView.addGestureRecognizer(tapGesture)

        applyCurrentState(force: true)
        enqueueNavigationCommand(from: renderState)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateOverscrollLayout()
        updateImageViews()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let viewportSize = view.bounds.size
        if viewportSize != lastReportedViewportSize, viewportSize.width > 0, viewportSize.height > 0
        {
            lastReportedViewportSize = viewportSize
            actions.viewportDidChange(viewportSize)
        }

        applyPendingNavigationCommand()
        isResizing = false
    }

    override func viewWillTransition(
        to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        isResizing = true
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.view.setNeedsLayout()
        }
    }

    func apply(
        state: ReaderRenderState, configuration: ReaderRenderConfiguration,
        actions: ReaderRenderActions
    ) {
        let chapterChanged = renderedChapterID != state.chapterID
        let contentChanged = renderedRevision != state.revision
        let configurationChanged = self.configuration != configuration

        renderState = state
        self.configuration = configuration
        self.actions = actions
        currentPage = state.currentPage

        guard isViewLoaded else { return }

        if chapterChanged { resetForChapter() }

        if chapterChanged || contentChanged || configurationChanged {
            applyCurrentState(force: true)
        }

        enqueueNavigationCommand(from: state)

        updateOverscrollViews()
        view.setNeedsLayout()
    }

    private func enqueueNavigationCommand(from state: ReaderRenderState) {
        guard let command = state.navigationCommand,
            command.generation > lastAppliedNavigationGeneration
        else { return }

        if command.generation > (pendingNavigationCommand?.generation ?? -1) {
            pendingNavigationCommand = command
        }

        guard !isNavigationCommandApplicationScheduled else { return }
        isNavigationCommandApplicationScheduled = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            isNavigationCommandApplicationScheduled = false
            guard pendingNavigationCommand != nil else { return }

            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
    }

    private func applyCurrentState(force: Bool) {
        guard force || renderedRevision != renderState.revision else { return }
        renderedRevision = renderState.revision
        renderedChapterID = renderState.chapterID
        groups = renderState.groups.map { ContinuousGroup(urls: $0.urls) }

        let activeURLs = Set(renderState.urls)
        let staleURLs = imageViews.keys.filter { !activeURLs.contains($0) }
        for url in staleURLs {
            imageViews[url]?.removeFromSuperview()
            imageViews[url] = nil
            imageSubscriptions[url] = nil
        }

        updateOverscrollViews()
        view.setNeedsLayout()
    }

    private func resetForChapter() {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        scrollView.setContentOffset(.zero, animated: false)
        imageViews.values.forEach { $0.removeFromSuperview() }
        imageViews.removeAll()
        imageSubscriptions.removeAll()
        groups.removeAll()
        currentGroupIndex = nil
        startY = 0
    }

    func viewForZooming(in _: UIScrollView) -> UIView? { contentView }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isResizing else { return }

        updateCurrentPageFromScroll()
        updateOverscrollViews()
    }

    func scrollViewWillBeginDragging(_: UIScrollView) { animatedNavigationGeneration = nil }

    func scrollViewDidEndScrollingAnimation(_: UIScrollView) { animatedNavigationGeneration = nil }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity _: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard configuration.snapToPage else { return }

        let zoomScale = scrollView.zoomScale
        let viewportHeight = view.bounds.height
        let viewportTop = targetContentOffset.pointee.y
        let viewportBottom = viewportTop + viewportHeight
        let viewportCenter = viewportTop + viewportHeight / 2
        var closestTargetY: CGFloat?
        var closestDistance = CGFloat.greatestFiniteMagnitude
        var shouldFreeScroll = false

        for (index, group) in groups.enumerated() {
            let groupTop = (group.y + startY) * zoomScale
            let groupHeight = group.height * zoomScale
            let groupBottom = groupTop + groupHeight
            let groupCenter = groupTop + groupHeight / 2
            var targetY: CGFloat
            var distance: CGFloat
            var freeScroll = false

            if index != currentGroupIndex || groupHeight <= viewportHeight {
                distance = abs(groupCenter - viewportCenter)
                targetY = groupCenter - viewportHeight / 2
            } else if viewportTop >= groupTop, viewportBottom <= groupBottom {
                distance = 0
                targetY = targetContentOffset.pointee.y
                freeScroll = true
            } else {
                let topDistance = abs(viewportTop - groupTop)
                let bottomDistance = abs(viewportBottom - groupBottom)
                if topDistance < bottomDistance {
                    distance = topDistance
                    targetY = groupTop
                } else {
                    distance = bottomDistance
                    targetY = groupBottom - viewportHeight
                }
            }

            if distance < closestDistance {
                closestDistance = distance
                closestTargetY = targetY
                shouldFreeScroll = freeScroll
            }
        }

        guard let closestTargetY, !shouldFreeScroll else { return }
        let maximumY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let maximumX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let targetY = max(0, min(closestTargetY, maximumY))
        let targetX = max(0, min(scrollView.contentOffset.x, maximumX))

        if configuration.softSnap {
            targetContentOffset.pointee.y = targetY
        } else {
            targetContentOffset.pointee = scrollView.contentOffset
            scrollView.setContentOffset(CGPoint(x: targetX, y: targetY), animated: true)
        }
    }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate _: Bool) {
        updateOverscrollViews()

        if topOverscrollController.progress >= 1, renderState.previousChapter == .available {
            actions.requestChapterStep(.previous)
        } else if bottomOverscrollController.progress >= 1, renderState.nextChapter == .available {
            actions.requestChapterStep(.next)
        }
    }

    private func updateCurrentPageFromScroll() {
        guard pendingNavigationCommand == nil, animatedNavigationGeneration == nil, !groups.isEmpty
        else { return }
        let viewportCenter = scrollView.contentOffset.y + view.bounds.height / 2
        var closestIndex = 0
        var closestDistance = CGFloat.greatestFiniteMagnitude

        for (index, group) in groups.enumerated() {
            let groupCenter = (group.y + group.height / 2) * scrollView.zoomScale + startY
            let distance = abs(groupCenter - viewportCenter)
            if distance < closestDistance {
                closestDistance = distance
                closestIndex = index
            }
        }

        currentGroupIndex = closestIndex
        guard let firstURL = groups[closestIndex].urls.first,
            let page = renderState.urls.firstIndex(of: firstURL), page != currentPage
        else { return }

        currentPage = page
        actions.pageDidChange(page)
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.maximumZoomScale = 3
        scrollView.delegate = self
        hideReaderScrollEdgeEffects(scrollView)

        containerView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(containerView)
        setupOverscrollViews()
    }

    private func setupConstraints() {
        scrollView.pinEdges(to: view)
        contentView.pinEdges(to: scrollView)

        containerLeadingConstraint = containerView.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor)
        containerTopConstraint = containerView.topAnchor.constraint(equalTo: contentView.topAnchor)
        containerWidthConstraint = containerView.widthAnchor.constraint(equalToConstant: 0)
        containerHeightConstraint = containerView.heightAnchor.constraint(equalToConstant: 0)
        contentHeightConstraint = contentView.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            contentHeightConstraint,

            containerLeadingConstraint, containerTopConstraint, containerWidthConstraint,
            containerHeightConstraint
        ])

        updateOverscrollLayout()
    }

    private func updateOverscrollLayout() {
        let insets = contentSafeAreaInsets
        topOverscrollController.spacing = readerOverscrollLayoutSpacing(safeAreaInset: insets.top)
        bottomOverscrollController.spacing = readerOverscrollLayoutSpacing(
            safeAreaInset: insets.bottom)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: view)
        let width = view.bounds.width

        guard configuration.tapNavigation else {
            actions.toggleChrome()
            return
        }

        if location.x < width / 3 {
            actions.requestGroupStep(.previous)
        } else if location.x > width * 2 / 3 {
            actions.requestGroupStep(.next)
        } else {
            actions.toggleChrome()
        }
    }

    private func makePlaceholderView(child: UIView, identifierTag: Int) -> UIView {
        let wrapper = UIView()
        child.translatesAutoresizingMaskIntoConstraints = false
        child.tag = identifierTag
        wrapper.addSubview(child)
        NSLayoutConstraint.activate([
            child.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            child.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor)
        ])
        return wrapper
    }

    private func view(for state: ReaderImageState, url: String) -> UIView {
        switch state { case .success(let image):
            let imageView = UIImageView(image: image.image)
            imageView.contentMode = .scaleToFill
            imageSubscriptions[url] = image.$image.receive(on: DispatchQueue.main)
                .sink { [weak self, weak imageView] processedImage in
                    imageView?.image = processedImage
                    self?.view.setNeedsLayout()
                }
            return imageView
            case .failed:
                let errorIconName: String
                if #available(iOS 18.0, *) {
                    errorIconName = "photo.badge.exclamationmark"
                } else {
                    errorIconName = "exclamationmark.circle.fill"
                }
                let icon = UIImageView(image: UIImage(systemName: errorIconName))
                icon.tintColor = .secondaryLabel
                NSLayoutConstraint.activate([
                    icon.widthAnchor.constraint(equalToConstant: 48),
                    icon.heightAnchor.constraint(equalToConstant: 48)
                ])
                return makePlaceholderView(child: icon, identifierTag: CONTINUOUS_ERROR_IMAGE_TAG)
            case .loading:
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                return makePlaceholderView(
                    child: spinner, identifierTag: CONTINUOUS_LOADING_IMAGE_TAG)
        }
    }

    private func reconcileImageView(url: String, frame: CGRect) {
        let state = renderState.images[url] ?? .loading
        if let existingView = imageViews[url], view(existingView, matches: state) {
            existingView.frame = frame
            return
        }

        imageViews[url]?.removeFromSuperview()
        imageSubscriptions[url] = nil
        let newView = view(for: state, url: url)
        newView.frame = frame
        imageViews[url] = newView
        containerView.addSubview(newView)
    }

    private func view(_ view: UIView, matches state: ReaderImageState) -> Bool {
        switch state { case .success(let image):
            return (view as? UIImageView)?.image === image.image
            case .failed: return view.viewWithTag(CONTINUOUS_ERROR_IMAGE_TAG) != nil
            case .loading: return view.viewWithTag(CONTINUOUS_LOADING_IMAGE_TAG) != nil
        }
    }

    private func calculateFrames(ratios: [String: CGFloat], mode: CGFloat) -> (
        [String: CGRect], CGFloat
    ) {
        let width = contentLayoutFrame.width
        guard width > 0 else { return ([:], 0) }

        let isRightToLeft = configuration.readingDirection == .rightToLeft
        var frames: [String: CGRect] = [:]
        var currentY: CGFloat = 0

        for index in groups.indices {
            let groupURLs = groups[index].urls
            guard let firstURL = groupURLs.first else { continue }
            let isSinglePortrait =
                configuration.defaultGroupSize != 1 && groupURLs.count == 1
                && ratios[firstURL, default: mode] < 1
            let effectiveWidth =
                isSinglePortrait ? width / CGFloat(configuration.defaultGroupSize) : width
            let ratioSum = groupURLs.reduce(CGFloat(0)) { result, url in
                result + ratios[url, default: mode]
            }
            let rowHeight = effectiveWidth / max(ratioSum, 0.01)
            var currentX: CGFloat = 0

            let orderedURLs = isRightToLeft ? Array(groupURLs.reversed()) : groupURLs
            for url in orderedURLs {
                let imageWidth = rowHeight * ratios[url, default: mode]
                let x = isSinglePortrait && isRightToLeft ? width - imageWidth : currentX
                frames[url] = CGRect(x: x, y: currentY, width: imageWidth, height: rowHeight)
                currentX += imageWidth
            }

            groups[index].y = currentY
            groups[index].height = rowHeight
            currentY += rowHeight
        }

        return (frames, currentY)
    }

    private func updateImageViews() {
        guard !renderState.urls.isEmpty else {
            containerHeightConstraint.constant = 0
            contentHeightConstraint.constant = max(view.bounds.height, 1)
            return
        }

        let ratios = renderState.images.compactMapValues { state -> CGFloat? in
            guard case .success(let image) = state else { return nil }
            return image.size.width / image.size.height
        }
        var roundedRatioCounts: [CGFloat: Int] = [:]
        for ratio in ratios.values {
            roundedRatioCounts[(ratio * 100).rounded() / 100, default: 0] += 1
        }
        let maximumRatioCount = roundedRatioCounts.values.max() ?? 0
        let mode = roundedRatioCounts.filter { $0.value == maximumRatioCount }.keys.min() ?? 1
        let (frames, finalY) = calculateFrames(ratios: ratios, mode: mode)

        for url in renderState.urls { reconcileImageView(url: url, frame: frames[url] ?? .zero) }

        startY = contentSafeAreaInsets.top
        containerLeadingConstraint.constant = contentSafeAreaInsets.left
        containerTopConstraint.constant = startY
        containerWidthConstraint.constant = contentLayoutFrame.width
        containerHeightConstraint.constant = finalY
        contentHeightConstraint.constant = max(
            finalY + startY + contentSafeAreaInsets.bottom, view.bounds.height)
    }

    private func applyPendingNavigationCommand() {
        guard let command = pendingNavigationCommand,
            command.generation != lastAppliedNavigationGeneration,
            let targetPage = renderState.urls.firstIndex(of: command.targetURL),
            let groupIndex = groups.firstIndex(where: { $0.contains(command.targetURL) })
        else { return }

        let group = groups[groupIndex]
        let centerY = group.y + group.height / 2
        let scaledCenterY = centerY * scrollView.zoomScale
        let targetY = scaledCenterY + startY - view.bounds.height / 2
        let maximumY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let clampedY = max(0, min(targetY, maximumY))
        let targetOffset = CGPoint(x: 0, y: clampedY)
        currentGroupIndex = groupIndex

        let targetGeometryIsStable = renderState.urls[...targetPage]
            .allSatisfy { url in
                guard let image = renderState.images[url] else { return false }
                if case .loading = image { return false }
                return true
            }
        guard targetGeometryIsStable else {
            scrollView.setContentOffset(targetOffset, animated: command.animated)
            return
        }

        lastAppliedNavigationGeneration = command.generation
        let offsetDelta = hypot(
            scrollView.contentOffset.x - targetOffset.x, scrollView.contentOffset.y - targetOffset.y
        )
        if command.animated, offsetDelta > 0.5 {
            animatedNavigationGeneration = command.generation
        } else {
            animatedNavigationGeneration = nil
        }
        scrollView.setContentOffset(targetOffset, animated: animatedNavigationGeneration != nil)
        pendingNavigationCommand = nil
    }

    private func setupOverscrollViews() {
        for indicator in [topOverscrollController, bottomOverscrollController] {
            addChild(indicator)
            indicator.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(indicator.view)
            NSLayoutConstraint.activate(
                indicator.positionConstraints(in: view, orientation: .vertical))
            indicator.didMove(toParent: self)
        }
    }

    private func updateOverscrollViews() {
        updateOverscrollLayout()
        let offsetY = scrollView.contentOffset.y
        let maximumY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        topOverscrollController.update(
            offset: offsetY, orientation: .vertical, step: .previous,
            availability: renderState.previousChapter)
        bottomOverscrollController.update(
            offset: offsetY - maximumY, orientation: .vertical, step: .next,
            availability: renderState.nextChapter)
    }
}

struct ContinuousReaderScreen: UIViewControllerRepresentable {
    let state: ReaderRenderState
    let configuration: ReaderRenderConfiguration
    let actions: ReaderRenderActions

    func makeUIViewController(context _: Context) -> ContinuousReaderViewController {
        ContinuousReaderViewController(state: state, configuration: configuration, actions: actions)
    }

    func updateUIViewController(
        _ viewController: ContinuousReaderViewController, context _: Context
    ) { viewController.apply(state: state, configuration: configuration, actions: actions) }
}
