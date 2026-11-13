//
//  ReaderSupport.swift
//  mankai
//
//  Created by Travis XU on 7/8/2026.
//

import SwiftUI
import UIKit

let READER_OVERSCROLL_THRESHOLD: CGFloat = 65
let READER_OVERSCROLL_MINIMUM_SPACING: CGFloat = 24
let READER_OVERSCROLL_INDICATOR_SIZE: CGFloat = 48

func readerOverscrollLayoutSpacing(safeAreaInset: CGFloat) -> CGFloat {
    max(
        max(READER_OVERSCROLL_MINIMUM_SPACING, safeAreaInset) - safeAreaInset,
        READER_OVERSCROLL_INDICATOR_SIZE * (1.4 - 1) / 2)
}

func readerOverscrollProgress(_ distance: CGFloat, spacing: CGFloat) -> CGFloat {
    let visibleDistance = max(distance - spacing, 0)
    return min(visibleDistance / READER_OVERSCROLL_THRESHOLD, 1)
}

func readerTapNavigationEdgeWidth(in viewportWidth: CGFloat) -> CGFloat {
    min(viewportWidth / 3, 160)
}

@MainActor struct ReaderRoute: Identifiable, Hashable {
    let plugin: Plugin
    let manga: DetailedManga
    let downloadManga: DetailedManga?
    let usesDownloadedMetadata: Bool
    let chapterGroupIndex: Int
    let chapter: Chapter
    let initialPage: Int?

    var id: String { "\(plugin.id):\(manga.id):\(chapterGroupIndex):\(chapter.id)" }

    static func == (lhs: ReaderRoute, rhs: ReaderRoute) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ReaderLoadPhase: Equatable {
    case idle
    case loading
    case ready
    case failed
}

enum ReaderImageState {
    case loading
    case success(AppImage)
    case failed
}

struct ReaderGroup: Identifiable, Hashable {
    var id: [String] { urls }

    let urls: [String]

    func contains(_ url: String) -> Bool { urls.contains(url) }
}

enum ReaderStep: Equatable {
    case previous
    case next
}

enum ReaderChapterAvailability: Equatable {
    case unavailable
    case locked
    case available
}

struct ReaderOverscrollIndicator: View {
    let progress: Double
    let direction: ProgressArrowDirection
    let step: ReaderStep
    let availability: ReaderChapterAvailability

    var body: some View {
        if availability == .available {
            ProgressArrowView(
                progress: progress, direction: direction, size: READER_OVERSCROLL_INDICATOR_SIZE,
                completionScale: 1.2)
        } else {
            ReaderOverscrollStatus(direction: direction, step: step, availability: availability)
        }
    }
}

struct ReaderOverscrollStatus: View {
    let direction: ProgressArrowDirection
    let step: ReaderStep
    let availability: ReaderChapterAvailability

    var isCentered = false

    var body: some View {
        let (systemName, text) = status
        Group {
            if isCentered {
                VStack(spacing: 16) {
                    Image(systemName: systemName).resizable().scaledToFit()
                        .frame(width: 48, height: 48)
                    Text(text).multilineTextAlignment(.center)
                }
            } else {
                let content = HStack(spacing: 8) {
                    Image(systemName: systemName)
                    Text(text)
                    Image(systemName: systemName)
                }

                switch direction { case .left, .right:
                    RotatedStatusLayout {
                        content.rotationEffect(.degrees(direction == .left ? -90 : 90))
                    }
                    case .up, .down: content
                }
            }
        }
        .foregroundStyle(Color(uiColor: .secondaryLabel))
    }

    private var status: (systemName: String, text: String) {
        switch availability { case .available:
            // The row rotation turns an upward arrow toward the horizontal chapter edge.
            return (
                direction == .down ? "arrow.down" : "arrow.up",
                step == .previous
                    ? String(localized: "turnToLoadPreviousChapter")
                    : String(localized: "turnToLoadNextChapter")
            )
            case .locked:
                return (
                    "lock.fill",
                    step == .previous
                        ? String(localized: "previousChapterIsLocked")
                        : String(localized: "nextChapterIsLocked")
                )
            case .unavailable:
                return (
                    "xmark",
                    step == .previous
                        ? String(localized: "noPreviousChapter")
                        : String(localized: "noNextChapter")
                )
        }
    }

    // rotationEffect leaves the layout size unchanged, so swap the axes for the hosting view.
    private struct RotatedStatusLayout: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize
        {
            let size = subviews[0]
                .sizeThatFits(ProposedViewSize(width: proposal.height, height: proposal.width))
            return CGSize(width: size.height, height: size.width)
        }

        func placeSubviews(
            in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) {
            subviews[0]
                .place(
                    at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                    proposal: ProposedViewSize(width: bounds.height, height: bounds.width))
        }
    }
}

final class ScrollOverscrollIndicatorController: UIHostingController<ReaderOverscrollIndicator> {
    let isLeading: Bool
    var progress: Double { rootView.progress }
    var spacing: CGFloat = READER_OVERSCROLL_MINIMUM_SPACING {
        didSet {
            guard spacing != oldValue else { return }
            positionConstraint?.constant = isLeading ? -spacing : spacing
        }
    }
    private var positionConstraint: NSLayoutConstraint?

    init(isLeading: Bool) {
        self.isLeading = isLeading
        super
            .init(
                rootView: ReaderOverscrollIndicator(
                    progress: 0, direction: .up, step: .previous, availability: .unavailable))
        sizingOptions = .intrinsicContentSize
        safeAreaRegions = []
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func positionConstraints(in container: UIView, orientation: NavigationOrientation)
        -> [NSLayoutConstraint]
    {
        let edge: NSLayoutConstraint
        let alignment: [NSLayoutConstraint]
        if orientation == .vertical {
            edge =
                isLeading
                ? view.bottomAnchor.constraint(equalTo: container.topAnchor, constant: -spacing)
                : view.topAnchor.constraint(equalTo: container.bottomAnchor, constant: spacing)
            alignment = [
                view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                view.widthAnchor.constraint(equalTo: container.widthAnchor)
            ]
        } else {
            edge =
                isLeading
                ? view.trailingAnchor.constraint(
                    equalTo: container.leadingAnchor, constant: -spacing)
                : view.leadingAnchor.constraint(
                    equalTo: container.trailingAnchor, constant: spacing)
            alignment = [
                view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                view.heightAnchor.constraint(equalTo: container.heightAnchor)
            ]
        }
        positionConstraint = edge
        return alignment + [edge]
    }

    func update(
        offset: CGFloat, orientation: NavigationOrientation, step: ReaderStep,
        isAtBoundary: Bool = true, availability: ReaderChapterAvailability
    ) {
        let distance = isAtBoundary ? max(isLeading ? -offset : offset, 0) : 0
        let translation = isLeading ? distance : -distance
        let isVertical = orientation == .vertical
        view.isHidden = !isAtBoundary
        view.transform = CGAffineTransform(
            translationX: isVertical ? 0 : translation, y: isVertical ? translation : 0)
        rootView = ReaderOverscrollIndicator(
            progress: Double(readerOverscrollProgress(distance, spacing: spacing)),
            direction: isVertical ? (isLeading ? .up : .down) : (isLeading ? .left : .right),
            step: step, availability: availability)
    }
}

struct ReaderNavigationCommand: Equatable {
    let generation: Int
    let targetURL: String
    let animated: Bool
}

struct ReaderRenderState {
    let revision: Int
    let chapterID: String?
    let urls: [String]
    let images: [String: ReaderImageState]
    let groups: [ReaderGroup]
    let currentPage: Int
    let navigationCommand: ReaderNavigationCommand?
    let previousChapter: ReaderChapterAvailability
    let nextChapter: ReaderChapterAvailability
}

struct ReaderRenderConfiguration: Equatable {
    // Common
    let contentSafeAreaInsets: UIEdgeInsets
    let readingDirection: ReadingDirection
    let defaultGroupSize: Int

    /// Dependent
    let tapNavigation: Bool

    // Paged Reader
    let tapNavigationBehavior: TapBehavior
    let navigationOrientation: NavigationOrientation
    let pageTransition: PageTransition

    // Continuous Reader
    let snapToPage: Bool
    let softSnap: Bool
}

struct ReaderRenderActions {
    let pageDidChange: (Int) -> Void
    let requestGroupStep: (ReaderStep) -> Void
    let requestChapterStep: (ReaderStep) -> Void
    let toggleChrome: () -> Void
    let viewportDidChange: (CGSize) -> Void
}
