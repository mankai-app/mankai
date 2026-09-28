//
//  UpscalingImageProcessor.swift
//  mankai
//
//  Created by Travis XU on 26/9/2026.
//

import Combine
import CoreImage
import Foundation

final class UpscalingImageProcessor: ImageProcessor, ObservableObject, @unchecked Sendable {
    static let type = "upscale"
    static let titleKey: LocalizedStringResource = "imageUpscaling"
    static let descriptionKey: LocalizedStringResource = "imageUpscalingDescription"
    @MainActor static var defaultProcessor: any ImageProcessor {
        Self(instanceID: UUID().uuidString, context: 16, threshold: Sensitivity.balanced.threshold)
    }

    let isFast = false
    @MainActor private(set) var instanceID: String
    @MainActor private(set) var context: Int
    @MainActor private(set) var threshold: Double

    @MainActor var configs: [Config] {
        [
            Config(
                key: "threshold", name: "upscaleSensitivity",
                description: String(localized: "upscaleSensitivityDescription"), type: .select,
                defaultValue: Sensitivity.balanced.localizedName,
                options: Sensitivity.allCases.map(\.localizedName))
        ]
    }

    @MainActor var configValues: [ConfigValue] {
        [ConfigValue(key: "threshold", value: Sensitivity(threshold).localizedName)]
    }

    @MainActor init(instanceID: String, context: Int, threshold: Double) {
        self.instanceID = instanceID
        self.context = context
        self.threshold = threshold
    }

    @MainActor func getConfig(_ key: String) -> Any {
        guard key == "threshold" else { return NSNull() }
        return Sensitivity(threshold).localizedName
    }

    @MainActor func setConfig(key: String, value: Any) throws {
        guard key == "threshold", let value = value as? String,
            let sensitivity = Sensitivity.allCases.first(where: { $0.localizedName == value })
        else { throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError() }

        threshold = sensitivity.threshold
        objectWillChange.send()
        ImageProcessingService.shared.update(id: instanceID, processor: self)
    }

    @MainActor func resetConfigs() throws {
        threshold = Sensitivity.balanced.threshold
        objectWillChange.send()
        ImageProcessingService.shared.update(id: instanceID, processor: self)
    }

    @MainActor func encode(id: String, order: Int, isEnabled: Bool) throws -> ImageProcessorModel {
        let configuration = try JSONEncoder()
            .encode(Configuration(context: context, threshold: threshold))
        return ImageProcessorModel(
            id: id, type: Self.type, order: order, isEnabled: isEnabled,
            configuration: String(decoding: configuration, as: UTF8.self))
    }

    @MainActor static func decode(_ model: ImageProcessorModel) throws -> any ImageProcessor {
        let configuration: Configuration
        do {
            configuration = try JSONDecoder()
                .decode(Configuration.self, from: Data(model.configuration.utf8))
        } catch {
            throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError(
                underlyingError: error)
        }
        guard (0...127).contains(configuration.context), configuration.threshold.isFinite,
            configuration.threshold > 0
        else { throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError() }
        return Self(
            instanceID: model.id, context: configuration.context, threshold: configuration.threshold
        )
    }

    private struct Configuration: Codable {
        let context: Int
        let threshold: Double
    }

    func process(image: CIImage, pointSize: CGSize) async throws -> CIImage {
        let (context, threshold) = await MainActor.run { (context, threshold) }

        guard threshold.isFinite else {
            Logger.imageProcessingService.debug(
                "Skipping image upscaling: invalid threshold \(threshold)")
            return image
        }
        guard threshold > 0 else {
            Logger.imageProcessingService.debug("Skipping image upscaling: sensitivity is off")
            return image
        }
        guard let maxPixelSize = Self.maxPixelSize(for: pointSize, multiplier: CGFloat(threshold))
        else {
            Logger.imageProcessingService.debug(
                "Skipping image upscaling: invalid display size \(pointSize)")
            return image
        }

        let sourceMaxPixelSize = Swift.max(image.extent.width, image.extent.height)
        guard sourceMaxPixelSize.isFinite, sourceMaxPixelSize > 0 else {
            Logger.imageProcessingService.debug(
                "Skipping image upscaling: invalid source max dimension \(sourceMaxPixelSize) px")
            return image
        }
        guard sourceMaxPixelSize < maxPixelSize else {
            Logger.imageProcessingService.debug(
                "Skipping image upscaling: source max dimension \(sourceMaxPixelSize) px meets or exceeds threshold \(maxPixelSize) px"
            )
            return image
        }

        return try await Upscaling.shared.upscale(image, context: context)
    }

    private enum Sensitivity: CaseIterable {
        case veryLow
        case low
        case balanced
        case high
        case maximum

        init(_ threshold: Double) {
            switch threshold { case ..<0.75: self = .veryLow case ..<1.25: self = .low case ..<1.75:
                self = .balanced
                case ..<2.25: self = .high
                default: self = .maximum
            }
        }

        var threshold: Double {
            switch self { case .veryLow: 0.5 case .low: 1 case .balanced: 1.5 case .high: 2
                case .maximum: 2.5
            }
        }

        var localizedName: String {
            switch self { case .veryLow: String(localized: "upscaleSensitivityVeryLow") case .low:
                String(localized: "upscaleSensitivityLow")
                case .balanced: String(localized: "upscaleSensitivityBalanced")
                case .high: String(localized: "upscaleSensitivityHigh")
                case .maximum: String(localized: "upscaleSensitivityMaximum")
            }
        }
    }
}

@MainActor extension UpscalingImageProcessor: Configurable {}
