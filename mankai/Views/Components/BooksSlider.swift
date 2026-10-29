//
//  BooksSlider.swift
//  mankai
//
//  Created by Travis XU on 24/9/2026.
//

import SwiftUI

struct BooksSlider: View {
    @Binding var value: Double

    let bounds: ClosedRange<Double>
    var readingDirection: ReadingDirection = .leftToRight
    var step: Double = 0
    var canScrub = true
    var previewTitle: String?
    var action: () -> Void = {}
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled

    @State private var isInteracting = false
    @State private var previewValue: Double?
    @State private var interactionStartValue: Double?
    @State private var feedbackTrigger = 0

    private var displayedValue: Double { previewValue ?? value }
    private var isRightToLeft: Bool { readingDirection == .rightToLeft }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let progress = normalizedProgress(for: displayedValue)
                let fillWidth = proxy.size.width * progress
                let fillPosition = isRightToLeft ? proxy.size.width - fillWidth / 2 : fillWidth / 2
                let startProgress = normalizedProgress(for: interactionStartValue ?? value)
                let markerProgress = isRightToLeft ? 1 - startProgress : startProgress
                let markerPosition = proxy.size.width * markerProgress

                ZStack {
                    Capsule().fill(.clear)

                    Rectangle().fill(Color.primary.opacity(0.24)).frame(width: fillWidth)
                        .position(x: fillPosition, y: proxy.size.height / 2)

                    if isInteracting {
                        Capsule().fill(Color.primary.opacity(0.58)).frame(width: 3, height: 28)
                            .position(
                                x: min(max(markerPosition, 3), proxy.size.width - 3),
                                y: proxy.size.height / 2
                            )
                            .transition(.opacity)
                    }
                }
                .clipShape(Capsule()).contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .local)
                        .onChanged { gesture in
                            guard canScrub else { return }
                            beginInteractionIfNeeded()
                            updatePreview(at: gesture.location.x, width: proxy.size.width)
                        }
                        .onEnded { gesture in
                            guard isInteracting else { return }
                            updatePreview(at: gesture.location.x, width: proxy.size.width)
                            endInteraction()
                        }
                )
                .onTapGesture(perform: action)
            }

            if !isInteracting {
                HStack {
                    HStack(spacing: 0) {
                        Text("chapters")
                        Text(verbatim: " · ")
                        Text(verbatim: "\(progressPercentage)%")
                    }
                    .lineLimit(1).layoutPriority(1)

                    Spacer()

                    Image(systemName: "list.bullet")
                }
                .padding(.horizontal, 16).allowsHitTesting(false).transition(.opacity)
            }
        }
        .frame(height: 44).adaptiveGlassBackground(in: Capsule()).opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
        .overlay(alignment: .bottom) {
            if let previewValue {
                BooksSliderPageIndicator(title: previewTitle, page: Int(previewValue.rounded()))
                    .frame(width: 240).offset(y: -56)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isInteracting)
        .sensoryFeedback(.selection, trigger: feedbackTrigger).zIndex(1)
    }

    private var progressPercentage: Int { Int((normalizedProgress(for: value) * 100).rounded()) }

    private func normalizedProgress(for value: Double) -> Double {
        guard bounds.upperBound > bounds.lowerBound else { return 0 }
        return min(max((value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound), 0), 1)
    }

    private func beginInteractionIfNeeded() {
        guard !isInteracting else { return }
        interactionStartValue = value
        previewValue = value
        isInteracting = true
        onEditingChanged(true)
    }

    private func updatePreview(at location: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let position = Double(min(max(location / width, 0), 1))
        let progress = isRightToLeft ? 1 - position : position

        let rawValue = bounds.lowerBound + progress * (bounds.upperBound - bounds.lowerBound)
        let newValue = normalized(rawValue)
        guard newValue != previewValue else { return }

        previewValue = newValue
        feedbackTrigger += 1
    }

    private func endInteraction() {
        if let previewValue, previewValue != value { value = previewValue }

        isInteracting = false
        previewValue = nil
        interactionStartValue = nil
        onEditingChanged(false)
    }

    private func normalized(_ newValue: Double) -> Double {
        let snappedValue: Double
        if step > 0 {
            let stepCount = ((newValue - bounds.lowerBound) / step).rounded()
            snappedValue = bounds.lowerBound + stepCount * step
        } else {
            snappedValue = newValue
        }

        return min(max(snappedValue, bounds.lowerBound), bounds.upperBound)
    }
}

private struct BooksSliderPageIndicator: View {
    let title: String?
    let page: Int

    var body: some View {
        VStack(spacing: 2) {
            if let title, !title.isEmpty { Text(verbatim: title).font(.subheadline).lineLimit(1) }

            Text(verbatim: String(format: String(localized: "pageFormat"), page.description))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 9).frame(maxWidth: .infinity)
        .adaptiveGlassBackground(in: Capsule())
    }
}
