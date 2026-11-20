//
//  ScanCleanupImageProcessor.swift
//  mankai
//
//  Created by Travis XU on 21/11/2026.
//

import Combine
import CoreImage
import Foundation

final class ScanCleanupImageProcessor: ImageProcessor, @unchecked Sendable {
    static let type = "scanCleanup"
    static let titleKey: LocalizedStringResource = "scanCleanup"
    static let descriptionKey: LocalizedStringResource = "scanCleanupDescription"

    private static let defaultBlackPoint = 0.05
    private static let defaultWhitePoint = 0.95
    private static let blackPointRange = 0.0...0.25
    private static let whitePointRange = 0.75...1.0

    @MainActor static var defaultProcessor: any ImageProcessor {
        Self(
            instanceID: UUID().uuidString, blackPoint: defaultBlackPoint,
            whitePoint: defaultWhitePoint)
    }

    let objectWillChange = ObservableObjectPublisher()
    let isFast = true
    private let instanceID: String
    @MainActor private var blackPoint: Double
    @MainActor private var whitePoint: Double

    @MainActor var configs: [Config] {
        [
            Config(
                key: "blackPoint", name: "scanCleanupBlackPoint",
                description: String(localized: "scanCleanupBlackPointDescription"), type: .slider,
                defaultValue: Self.defaultBlackPoint, min: Self.blackPointRange.lowerBound,
                max: Self.blackPointRange.upperBound, step: 0.01),
            Config(
                key: "whitePoint", name: "scanCleanupWhitePoint",
                description: String(localized: "scanCleanupWhitePointDescription"), type: .slider,
                defaultValue: Self.defaultWhitePoint, min: Self.whitePointRange.lowerBound,
                max: Self.whitePointRange.upperBound, step: 0.01)
        ]
    }

    @MainActor var configValues: [ConfigValue] {
        [
            ConfigValue(key: "blackPoint", value: blackPoint),
            ConfigValue(key: "whitePoint", value: whitePoint)
        ]
    }

    @MainActor private init(instanceID: String, blackPoint: Double, whitePoint: Double) {
        self.instanceID = instanceID
        self.blackPoint = blackPoint
        self.whitePoint = whitePoint
    }

    @MainActor func getConfig(_ key: String) -> Any {
        switch key { case "blackPoint": blackPoint case "whitePoint": whitePoint default: NSNull()
        }
    }

    @MainActor func setConfig(key: String, value: Any) throws {
        guard let value = value as? Double else {
            throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError()
        }

        switch key { case "blackPoint" where Self.blackPointRange.contains(value):
            guard blackPoint != value else { return }
            blackPoint = value
            case "whitePoint" where Self.whitePointRange.contains(value):
                guard whitePoint != value else { return }
                whitePoint = value
            default: throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError()
        }

        objectWillChange.send()
        ImageProcessingService.shared.update(id: instanceID, processor: self)
    }

    @MainActor func resetConfigs() throws {
        blackPoint = Self.defaultBlackPoint
        whitePoint = Self.defaultWhitePoint
        objectWillChange.send()
        ImageProcessingService.shared.update(id: instanceID, processor: self)
    }

    @MainActor func makeModel(id: String, order: Int, isEnabled: Bool) -> ImageProcessorModel {
        ImageProcessorModel(
            id: id, type: Self.type, order: order, isEnabled: isEnabled,
            configuration: .init(blackPoint: blackPoint, whitePoint: whitePoint))
    }

    @MainActor static func fromDataModel(_ model: ImageProcessorModel) throws -> any ImageProcessor
    {
        let blackPoint = model.configuration.blackPoint ?? Self.defaultBlackPoint
        let whitePoint = model.configuration.whitePoint ?? Self.defaultWhitePoint
        guard Self.blackPointRange.contains(blackPoint), Self.whitePointRange.contains(whitePoint)
        else { throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError() }

        return Self(instanceID: model.id, blackPoint: blackPoint, whitePoint: whitePoint)
    }

    func process(image: CIImage, pointSize _: CGSize) async throws -> CIImage {
        try Task.checkCancellation()
        let (blackPoint, whitePoint) = await MainActor.run { (self.blackPoint, self.whitePoint) }
        let extent = image.extent
        guard blackPoint > 0 || whitePoint < 1, !extent.isEmpty, !extent.isInfinite, !extent.isNull
        else { return image }

        let black = Self.linearComponent(for: blackPoint)
        let scale = 1 / (Self.linearComponent(for: whitePoint) - black)
        let bias = -black * scale

        let weights = CIVector(x: 0.3 * scale, y: 0.59 * scale, z: 0.11 * scale, w: 0)
        let opaque = image.unpremultiplyingAlpha().settingAlphaOne(in: extent)
        let adjustedLuminance =
            opaque.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": weights, "inputGVector": weights, "inputBVector": weights,
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
                ]
            )
            .applyingFilter("CIColorClamp")

        return
            adjustedLuminance.applyingFilter(
                "CILuminosityBlendMode", parameters: [kCIInputBackgroundImageKey: opaque]
            )
            .applyingFilter(
                "CIBlendWithAlphaMask",
                parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
                    kCIInputMaskImageKey: image
                ]
            )
            .cropped(to: extent)
    }

    private static func linearComponent(for value: Double) -> CGFloat {
        CGFloat(value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4))
    }
}

@MainActor extension ScanCleanupImageProcessor: Configurable {}
