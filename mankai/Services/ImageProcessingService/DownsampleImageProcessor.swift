//
//  DownsampleImageProcessor.swift
//  mankai
//
//  Created by Travis XU on 26/9/2026.
//

import Combine
import CoreImage
import Foundation

final class DownsampleImageProcessor: ImageProcessor, ObservableObject, @unchecked Sendable {
    static let type = "downsample"
    static let titleKey: LocalizedStringResource = "downsampleImages"
    static let descriptionKey: LocalizedStringResource = "downsampleImagesDescription"
    @MainActor static var defaultProcessor: any ImageProcessor {
        Self(instanceID: UUID().uuidString, aggressiveness: MemorySavings.balanced.aggressiveness)
    }

    let isFast = true
    @MainActor private(set) var instanceID: String
    @MainActor private(set) var aggressiveness: Double

    @MainActor var configs: [Config] {
        [
            Config(
                key: "aggressiveness", name: "downsampleMemorySavings",
                description: String(localized: "downsampleMemorySavingsDescription"), type: .select,
                defaultValue: MemorySavings.balanced.localizedName,
                options: MemorySavings.allCases.map(\.localizedName))
        ]
    }

    @MainActor var configValues: [ConfigValue] {
        [ConfigValue(key: "aggressiveness", value: MemorySavings(aggressiveness).localizedName)]
    }

    @MainActor init(instanceID: String, aggressiveness: Double) {
        self.instanceID = instanceID
        self.aggressiveness = aggressiveness
    }

    @MainActor func getConfig(_ key: String) -> Any {
        guard key == "aggressiveness" else { return NSNull() }
        return MemorySavings(aggressiveness).localizedName
    }

    @MainActor func setConfig(key: String, value: Any) throws {
        guard key == "aggressiveness", let value = value as? String,
            let memorySavings = MemorySavings.allCases.first(where: { $0.localizedName == value })
        else { throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError() }

        aggressiveness = memorySavings.aggressiveness
        objectWillChange.send()
        ImageProcessingService.shared.update(id: instanceID, processor: self)
    }

    @MainActor func resetConfigs() throws {
        aggressiveness = MemorySavings.balanced.aggressiveness
        objectWillChange.send()
        ImageProcessingService.shared.update(id: instanceID, processor: self)
    }

    @MainActor func encode(id: String, order: Int, isEnabled: Bool) throws -> ImageProcessorModel {
        let configuration = try JSONEncoder().encode(Configuration(aggressiveness: aggressiveness))
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
        guard configuration.aggressiveness.isFinite, (0...1).contains(configuration.aggressiveness)
        else { throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError() }
        return Self(instanceID: model.id, aggressiveness: configuration.aggressiveness)
    }

    private struct Configuration: Codable { let aggressiveness: Double }

    func process(image: CIImage, pointSize: CGSize) async throws -> CIImage {
        let aggressiveness = await MainActor.run { aggressiveness }

        guard
            let maxPixelSize = Self.maxPixelSize(
                for: pointSize, multiplier: Self.multiplier(for: aggressiveness))
        else {
            Logger.imageProcessingService.debug(
                "Skipping image downsampling: invalid display size \(pointSize)")
            return image
        }
        let sourceMaxPixelSize = Swift.max(image.extent.width, image.extent.height)
        guard sourceMaxPixelSize.isFinite, sourceMaxPixelSize > maxPixelSize else {
            Logger.imageProcessingService.debug(
                "Skipping image downsampling: source max dimension \(sourceMaxPixelSize) px does not exceed target \(maxPixelSize) px"
            )
            return image
        }

        let scale = maxPixelSize / sourceMaxPixelSize
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func multiplier(for aggressiveness: Double) -> CGFloat {
        guard aggressiveness.isFinite else { return 2 }

        let normalizedAggressiveness = min(max(aggressiveness, 0), 1)
        return 3 - (CGFloat(normalizedAggressiveness) * 2)
    }

    private enum MemorySavings: CaseIterable {
        case low
        case balanced
        case high

        init(_ aggressiveness: Double) {
            switch aggressiveness { case ..<0.25: self = .low case ..<0.75: self = .balanced
                default: self = .high
            }
        }

        var aggressiveness: Double {
            switch self { case .low: 0 case .balanced: 0.5 case .high: 1
            }
        }

        var localizedName: String {
            switch self { case .low: String(localized: "downsampleMemorySavingsLow") case .balanced:
                String(localized: "downsampleMemorySavingsBalanced")
                case .high: String(localized: "downsampleMemorySavingsHigh")
            }
        }
    }
}

@MainActor extension DownsampleImageProcessor: Configurable {}
