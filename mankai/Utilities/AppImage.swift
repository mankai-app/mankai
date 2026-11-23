//
//  AppImage.swift
//  mankai
//
//  Created by Travis XU on 10/8/2026.
//

import Combine
import CoreImage
import UIKit

/// A reader image that publishes a processed replacement when needed.
@MainActor final class AppImage: ObservableObject {
    enum SlideEdge {
        case left
        case right
    }

    nonisolated private static let sourceSlideWidth = SmartGrouping.inputSize.width
    nonisolated private static let outputSlideSize = CGSize(
        width: SmartGrouping.inputSize.width / 2, height: SmartGrouping.inputSize.height)

    @Published private(set) var image: UIImage
    @Published private(set) var isProcessingFinished = false
    private(set) var backgroundColor: SIMD3<Double>?

    private var processingTask: Task<UIImage?, Never>?
    private var slideTask: Task<(left: CIImage, right: CIImage)?, Never>?
    private var leftSlide: CIImage?
    private var rightSlide: CIImage?

    var size: CGSize { image.size }

    static func load(data: Data) async -> AppImage? {
        guard let prepared = await ImageProcessingService.shared.load(data: data) else {
            return nil
        }
        let backgroundColor = await detectBackgroundColor(in: prepared.image)
        return AppImage(
            image: prepared.image, backgroundColor: backgroundColor, data: data,
            processingTask: prepared.processingTask)
    }

    private init(
        image: UIImage, backgroundColor: SIMD3<Double>?, data: Data,
        processingTask: Task<UIImage?, Never>?
    ) {
        self.image = image
        self.backgroundColor = backgroundColor
        self.processingTask = processingTask
        isProcessingFinished = processingTask == nil

        slideTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled,
                let image = CIImage(data: data, options: [.applyOrientationProperty: true])
            else { return nil }

            return Self.makeSlides(from: image)
        }

        if let processingTask {
            Task { @MainActor [weak self] in
                let processedImage = await processingTask.value
                guard !processingTask.isCancelled else { return }

                if let processedImage {
                    let color = await Self.detectBackgroundColor(in: processedImage)
                    guard !processingTask.isCancelled, let self else { return }
                    self.backgroundColor = color
                    self.image = processedImage
                }
                self?.isProcessingFinished = true
            }
        }
    }

    /// Returns one generated edge slide and releases the stored reference immediately.
    /// Each edge can only be read once.
    func takeSlide(_ edge: SlideEdge) async -> CIImage? {
        if let slideTask {
            if let slides = await slideTask.value {
                leftSlide = slides.left
                rightSlide = slides.right
            }
            self.slideTask = nil
        }

        switch edge { case .left:
            defer { leftSlide = nil }
            return leftSlide
            case .right:
                defer { rightSlide = nil }
                return rightSlide
        }
    }

    func releaseSlides() {
        slideTask?.cancel()
        slideTask = nil
        leftSlide = nil
        rightSlide = nil
    }

    isolated deinit {
        processingTask?.cancel()
        slideTask?.cancel()
    }

    private static func detectBackgroundColor(in image: UIImage) async -> SIMD3<Double>? {
        guard let cgImage = image.cgImage else { return nil }
        return
            await Task.detached { () -> SIMD3<Double>? in
                let length = 16
                guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                    let context = CGContext(
                        data: nil, width: length, height: length, bitsPerComponent: 8,
                        bytesPerRow: length * 4, space: colorSpace,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                            | CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data
                else { return nil }

                let width = CGFloat(cgImage.width)
                let height = CGFloat(cgImage.height)
                let size = CGFloat(length)
                let strips: [(source: CGRect, destination: CGRect)] = [
                    (
                        CGRect(x: 0, y: 0, width: width, height: 1),
                        CGRect(x: 0, y: 0, width: size, height: 1)
                    ),
                    (
                        CGRect(x: 0, y: height - 1, width: width, height: 1),
                        CGRect(x: 0, y: size - 1, width: size, height: 1)
                    ),
                    (
                        CGRect(x: 0, y: 0, width: 1, height: height),
                        CGRect(x: 0, y: 0, width: 1, height: size)
                    ),
                    (
                        CGRect(x: width - 1, y: 0, width: 1, height: height),
                        CGRect(x: size - 1, y: 0, width: 1, height: size)
                    )
                ]

                context.clear(CGRect(x: 0, y: 0, width: size, height: size))
                context.interpolationQuality = .none
                context.setBlendMode(.copy)
                for strip in strips {
                    if let edge = cgImage.cropping(to: strip.source) {
                        context.draw(edge, in: strip.destination)
                    }
                }

                let pixels = data.bindMemory(to: UInt8.self, capacity: length * length * 4)
                var colorCounts: [SIMD3<Double>: Int] = [:]
                var mostCommonColor: SIMD3<Double>?
                var highestCount = 0
                for index in 0..<(length * length) {
                    let offset = index * 4
                    let alpha = Double(pixels[offset + 3])
                    guard alpha >= 128 else { continue }

                    let color = SIMD3(
                        Double(pixels[offset]) / alpha, Double(pixels[offset + 1]) / alpha,
                        Double(pixels[offset + 2]) / alpha)
                    let count = colorCounts[color, default: 0] + 1
                    colorCounts[color] = count
                    if count > highestCount {
                        highestCount = count
                        mostCommonColor = color
                    }
                }
                return mostCommonColor
            }
            .value
    }

    nonisolated private static func makeSlides(from image: CIImage) -> (
        left: CIImage, right: CIImage
    )? {
        let extent = image.extent.standardized
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0
        else { return nil }

        let imageAtOrigin = image.cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))

        let slideWidth = min(sourceSlideWidth, extent.width)
        let leftSlide = imageAtOrigin.cropped(
            to: CGRect(x: 0, y: 0, width: slideWidth, height: extent.height))

        let rightOriginX = max(0, extent.width - sourceSlideWidth)
        let rightSlide =
            imageAtOrigin.cropped(
                to: CGRect(x: rightOriginX, y: 0, width: slideWidth, height: extent.height)
            )
            .transformed(by: CGAffineTransform(translationX: -rightOriginX, y: 0))

        return (left: resizeSlide(leftSlide), right: resizeSlide(rightSlide))
    }

    nonisolated private static func resizeSlide(_ image: CIImage) -> CIImage {
        let scaleX = outputSlideSize.width / image.extent.width
        let scaleY = outputSlideSize.height / image.extent.height

        return image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: CGRect(origin: .zero, size: outputSlideSize))
    }

}
