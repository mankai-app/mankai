//
//  PaperTintImageProcessor.swift
//  mankai
//
//  Created by Travis XU on 21/11/2026.
//

import Combine
import CoreImage
import Foundation
import SwiftUI

final class PaperTintImageProcessor: ImageProcessor, @unchecked Sendable {
    static let type = "paperTint"
    static let titleKey: LocalizedStringResource = "paperTint"
    static let descriptionKey: LocalizedStringResource = "paperTintDescription"

    private static let defaultColor = "#F6E8CF"
    private static let defaultStrength = 0.7

    @MainActor static var defaultProcessor: any ImageProcessor {
        Self(instanceID: UUID().uuidString, color: defaultColor, strength: defaultStrength)
    }

    let objectWillChange = ObservableObjectPublisher()
    let isFast = true
    private let instanceID: String
    @MainActor private var color: String
    @MainActor private var strength: Double

    @MainActor var configs: [Config] {
        [
            Config(
                key: "color", name: "paperTintColor", type: .color, defaultValue: Self.defaultColor),
            Config(
                key: "intensity", name: "toneStrength",
                description: String(localized: "toneStrengthDescription"), type: .slider,
                defaultValue: Self.defaultStrength, min: 0, max: 1, step: 0.05)
        ]
    }

    @MainActor var configValues: [ConfigValue] {
        [ConfigValue(key: "color", value: color), ConfigValue(key: "intensity", value: strength)]
    }

    @MainActor private init(instanceID: String, color: String, strength: Double) {
        self.instanceID = instanceID
        self.color = color
        self.strength = strength
    }

    @MainActor func getConfig(_ key: String) -> Any {
        switch key { case "color": color case "intensity": strength default: NSNull()
        }
    }

    @MainActor func setConfig(key: String, value: Any) throws {
        switch key { case "color":
            guard let value = value as? String, let newColor = Color(hex: value)?.hex else {
                throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError()
            }
            guard color != newColor else { return }
            color = newColor
            case "intensity":
                guard let value = value as? Double, (0...1).contains(value) else {
                    throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError()
                }
                guard strength != value else { return }
                strength = value
            default: throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError()
        }

        objectWillChange.send()
        ImageProcessingService.shared.update(id: instanceID, processor: self)
    }

    @MainActor func resetConfigs() throws {
        color = Self.defaultColor
        strength = Self.defaultStrength
        objectWillChange.send()
        ImageProcessingService.shared.update(id: instanceID, processor: self)
    }

    @MainActor func makeModel(id: String, order: Int, isEnabled: Bool) -> ImageProcessorModel {
        ImageProcessorModel(
            id: id, type: Self.type, order: order, isEnabled: isEnabled,
            configuration: .init(color: color, intensity: strength))
    }

    @MainActor static func fromDataModel(_ model: ImageProcessorModel) throws -> any ImageProcessor
    {
        let configuration = model.configuration
        let strength = configuration.intensity ?? Self.defaultStrength
        guard let color = Color(hex: configuration.color ?? Self.defaultColor)?.hex,
            (0...1).contains(strength)
        else { throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError() }

        return Self(instanceID: model.id, color: color, strength: strength)
    }

    func process(image: CIImage, pointSize _: CGSize) async throws -> CIImage {
        try Task.checkCancellation()
        let (color, strength) = await MainActor.run { (self.color, self.strength) }
        let extent = image.extent
        guard strength > 0, color != "#FFFFFF", !extent.isEmpty, !extent.isInfinite, !extent.isNull
        else { return image }
        guard let paperColor = Color(hex: color) else {
            throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError()
        }

        // Scale RGB in the pipeline's linear working space.
        let tint = paperColor.resolve(in: EnvironmentValues())
        let red = 1 + CGFloat(strength) * (CGFloat(tint.linearRed) - 1)
        let green = 1 + CGFloat(strength) * (CGFloat(tint.linearGreen) - 1)
        let blue = 1 + CGFloat(strength) * (CGFloat(tint.linearBlue) - 1)
        let tinted = image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: red, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: green, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: blue, w: 0)
            ])
        return tinted.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: Self.paperMask(for: image)
            ])
    }

    private static func paperMask(for image: CIImage) -> CIImage {
        // Require all three channels to be bright so vivid colors receive less tint.
        let start: CGFloat = 0.45
        let end: CGFloat = 0.85
        let scale = 1 / (end - start)
        let offset = -start * scale
        let weights = CIVector(x: scale, y: 0, z: 0, w: 0)

        return image.unpremultiplyingAlpha().settingAlphaOne(in: image.extent)
            .applyingFilter("CIMinimumComponent")
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": weights, "inputGVector": weights, "inputBVector": weights,
                    "inputBiasVector": CIVector(x: offset, y: offset, z: offset, w: 0)
                ]
            )
            .applyingFilter("CIColorClamp")
    }
}

@MainActor extension PaperTintImageProcessor: Configurable {}
