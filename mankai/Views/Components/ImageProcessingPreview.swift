//
//  ImageProcessingPreview.swift
//  mankai
//
//  Created by Travis XU on 20/11/2026.
//

import SwiftUI
import UIKit

struct ImageProcessingPreview: View {
    @ObservedObject var service: ImageProcessingService
    @AppStorage(SettingsKey.imageProcessorPreviewImage.rawValue) private var selectedImage =
        SettingsDefaults.imageProcessorPreviewImage
    @State private var revision = 0
    @State private var result: (request: RenderRequest, image: UIImage?)?

    private var hasFailed: Bool {
        guard let result else { return false }
        return result.image == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("imageProcessorPreviewImage", selection: $selectedImage) {
                Text("imageProcessorPreviewGreatWave").tag(ImageProcessorPreviewImage.greatWave)
                Text("imageProcessorPreviewMangaBackground")
                    .tag(ImageProcessorPreviewImage.mangaBackground)
                Text("imageProcessorPreviewTramStation").tag(ImageProcessorPreviewImage.tramStation)
            }
            .pickerStyle(.menu)

            if let sample {
                let request = RenderRequest(
                    source: ObjectIdentifier(sample.image), revision: revision)
                let activeRequest = hasFailed ? nil : request
                let image = result?.request.source == request.source ? result?.image : nil

                ImageComparison(
                    before: sample.image, after: image,
                    isRendering: activeRequest != nil && result?.request != request,
                    onRetry: { result = nil }
                )
                .task(id: activeRequest) {
                    if let activeRequest { await render(sample, request: activeRequest) }
                }
            } else {
                Text("imageProcessorPreviewUnavailable").foregroundStyle(.secondary)
            }
        }
        .onReceive(service.previewChanges) { _ in revision &+= 1 }
    }

    private var sample: Sample? {
        let enabledProcessors = service.processors.filter(\.isEnabled)
        let hasUpscaling = enabledProcessors.contains { $0.processor is UpscalingImageProcessor }
        let hasDownsampling = enabledProcessors.contains {
            $0.processor is DownsampleImageProcessor
        }
        let useReducedImage = hasUpscaling && !hasDownsampling
        switch (selectedImage, useReducedImage) { case (.greatWave, false): return Self.greatWave
            case (.greatWave, true): return Self.greatWaveReduced
            case (.mangaBackground, false): return Self.mangaBackground
            case (.mangaBackground, true): return Self.mangaBackgroundReduced
            case (.tramStation, false): return Self.tramStation
            case (.tramStation, true): return Self.tramStationReduced
        }
    }

    private func render(_ sample: Sample, request: RenderRequest) async {
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }

        let image = await service.render(
            data: sample.data, pointSize: UIApplication.windowBounds.size)
        guard !Task.isCancelled, request.revision == revision, self.sample?.image === sample.image
        else { return }
        result = (request, image)
    }

    // Katsushika Hokusai, Under the Wave off Kanagawa (JP10), The Metropolitan Museum of Art.
    // Both sizes use The Met's CC0 scan: https://www.metmuseum.org/art/collection/search/36491
    private static let greatWave = Sample(assetName: "ImageProcessorPreviewGreatWave")
    private static let greatWaveReduced = Sample(assetName: "ImageProcessorPreviewGreatWaveReduced")

    // Pavel Kutejnikov, Manga-style background (manga_bg_01.png), CC0.
    // https://opengameart.org/content/manga-style-background
    private static let mangaBackground = Sample(assetName: "ImageProcessorPreviewMangaBackground")
    private static let mangaBackgroundReduced = Sample(
        assetName: "ImageProcessorPreviewMangaBackgroundReduced")

    private static let tramStation = Sample(assetName: "ImageProcessorPreviewTramStation")
    private static let tramStationReduced = Sample(
        assetName: "ImageProcessorPreviewTramStationReduced")

    private struct RenderRequest: Equatable {
        let source: ObjectIdentifier
        let revision: Int
    }

    private struct Sample {
        let data: Data
        let image: UIImage

        init?(assetName: String) {
            guard let asset = NSDataAsset(name: assetName), let image = UIImage(data: asset.data)
            else { return nil }
            data = asset.data
            self.image = image
        }
    }
}

private struct ImageComparison: View {
    private static let handleSize: CGFloat = 44
    // The aspect ratio of the full-resolution Great Wave sample.
    private static let aspectRatio: CGFloat = 3200.0 / 2209.0

    let before: UIImage
    let after: UIImage?
    let isRendering: Bool
    let onRetry: () -> Void

    @State private var split: CGFloat = 0.5
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in comparison(in: geometry.size) }
                .aspectRatio(Self.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if isRendering {
                        ProgressView().padding(8).background(.regularMaterial, in: Circle())
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .top) {
                    if !isRendering && after == nil {
                        VStack(spacing: 4) {
                            Text("imageProcessorPreviewUnavailable").font(.caption)
                                .multilineTextAlignment(.center)
                            Button("retry", action: onRetry).buttonStyle(.bordered)
                        }
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(8)
                    }
                }

            HStack(alignment: .top, spacing: 12) {
                caption("imageProcessorPreviewBefore", image: before, alignment: .leading)
                Spacer(minLength: 0)
                caption("imageProcessorPreviewAfter", image: after, alignment: .trailing)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func comparison(in size: CGSize) -> some View {
        let handleInset = min(Self.handleSize / 2, size.width / 2)
        let trackWidth = size.width - 2 * handleInset
        let dividerX = handleInset + dividerOffset(for: dragOffset, trackWidth: trackWidth)

        return ZStack {
            if let after {
                layer(after, in: size)
                layer(before, in: size)
                    .mask(alignment: .leading) { Rectangle().frame(width: dividerX) }

                ZStack {
                    Rectangle().fill(.white).frame(width: 2, height: size.height)
                        .allowsHitTesting(false)

                    handle(trackWidth: trackWidth)
                }
                .position(x: dividerX, y: size.height / 2)
            } else {
                layer(before, in: size)
            }
        }
    }

    private func layer(_ image: UIImage, in size: CGSize) -> some View {
        Image(uiImage: image).resizable().scaledToFit()
            .frame(width: size.width, height: size.height)
            .background(Color(uiColor: .secondarySystemBackground)).allowsHitTesting(false)
    }

    private func handle(trackWidth: CGFloat) -> some View {
        Image(systemName: "arrow.left.and.right").font(.system(size: 14, weight: .semibold))
            .frame(width: 34, height: 34).background(.regularMaterial, in: Circle())
            .frame(width: Self.handleSize, height: Self.handleSize).contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .updating($dragOffset) { value, offset, _ in offset = value.translation.width }
                    .onEnded { value in
                        guard trackWidth > 0 else { return }
                        split =
                            dividerOffset(for: value.translation.width, trackWidth: trackWidth)
                            / trackWidth
                    })
    }

    private func caption(
        _ title: LocalizedStringKey, image: UIImage?, alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            if let pixels = image?.cgImage {
                Text(verbatim: "\(pixels.width.formatted()) × \(pixels.height.formatted()) px")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func dividerOffset(for translation: CGFloat, trackWidth: CGFloat) -> CGFloat {
        min(max(split * trackWidth + translation, 0), trackWidth)
    }
}
