//
//  MonochromeToneImageProcessor.swift
//  mankai
//
//  Created by Travis XU on 29/9/2026.
//

import Combine
import CoreImage
import Foundation
import SwiftUI

final class MonochromeToneImageProcessor: ImageProcessor, ObservableObject, @unchecked Sendable {
    static let type = "tint"
    static let titleKey: LocalizedStringResource = "monochromeTone"
    static let descriptionKey: LocalizedStringResource = "monochromeToneDescription"

    private static let defaultStrength = 0.7

    @MainActor private static var defaultColor: String {
        let storedValue = UserDefaults.standard.string(forKey: SettingsKey.accentColor.rawValue)
        let accentColor =
            storedValue.flatMap { AppAccentColor(rawValue: $0) } ?? SettingsDefaults.accentColor
        return accentColor.color.hex ?? "#FF8688"
    }

    @MainActor static var defaultProcessor: any ImageProcessor {
        Self(instanceID: UUID().uuidString, colorOverride: nil, strength: defaultStrength)
    }

    let isFast = true
    @MainActor private(set) var instanceID: String
    @MainActor private var colorOverride: String?
    @MainActor private(set) var strength: Double

    @MainActor private var color: String { colorOverride ?? Self.defaultColor }

    @MainActor var configs: [Config] {
        [
            Config(
                key: "color", name: "toneColor",
                description: String(localized: "toneColorDescription"), type: .color,
                defaultValue: Self.defaultColor),
            Config(
                key: "intensity", name: "toneStrength",
                description: String(localized: "toneStrengthDescription"), type: .slider,
                defaultValue: Self.defaultStrength, min: 0, max: 1, step: 0.1)
        ]
    }

    @MainActor var configValues: [ConfigValue] {
        [ConfigValue(key: "color", value: color), ConfigValue(key: "intensity", value: strength)]
    }

    @MainActor private init(instanceID: String, colorOverride: String?, strength: Double) {
        self.instanceID = instanceID
        self.colorOverride = colorOverride
        self.strength = strength
    }

    @MainActor func getConfig(_ key: String) -> Any {
        switch key { case "color": color case "intensity": strength default: NSNull()
        }
    }

    @MainActor func setConfig(key: String, value: Any) throws {
        switch key { case "color":
            guard let value = value as? String, let color = Color(hex: value)?.hex else {
                throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError()
            }
            colorOverride = color
            case "intensity":
                guard let value = value as? Double, value.isFinite, (0...1).contains(value) else {
                    throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError()
                }
                strength = value
            default: throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError()
        }

        objectWillChange.send()
        ImageProcessingService.shared.update(id: instanceID, processor: self)
    }

    @MainActor func resetConfigs() throws {
        colorOverride = nil
        strength = Self.defaultStrength
        objectWillChange.send()
        ImageProcessingService.shared.update(id: instanceID, processor: self)
    }

    @MainActor func encode(id: String, order: Int, isEnabled: Bool) throws -> ImageProcessorModel {
        let configuration = try JSONEncoder()
            .encode(Configuration(color: colorOverride, intensity: strength))
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

        let strength = configuration.intensity ?? Self.defaultStrength
        let colorOverride: String?
        if let color = configuration.color {
            guard let color = Color(hex: color)?.hex else {
                throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError()
            }
            colorOverride = color
        } else {
            colorOverride = nil
        }
        guard strength.isFinite, (0...1).contains(strength) else {
            throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError()
        }

        return Self(instanceID: model.id, colorOverride: colorOverride, strength: strength)
    }

    func process(image: CIImage, pointSize: CGSize) async throws -> CIImage {
        try Task.checkCancellation()
        let (color, strength) = await MainActor.run { (color, strength) }
        guard let tone = RGB(hex: color), strength.isFinite, (0...1).contains(strength) else {
            throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError()
        }

        let extent = image.extent
        guard extent.isUsable else { return image }

        let monochrome = image.unpremultiplyingAlpha().settingAlphaOne(in: extent)
            .applyingFilter(
                "CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.08]
            )

        let toned = monochrome.applyingFilter(
            "CIColorPolynomial", parameters: tone.polynomial(strength: CGFloat(strength)))

        try Task.checkCancellation()
        let sharpened = toned.clampedToExtent()
            .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.35])
            .cropped(to: extent).applyingFilter("CIColorClamp")

        return
            sharpened.applyingFilter(
                "CIBlendWithAlphaMask",
                parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
                    kCIInputMaskImageKey: image
                ]
            )
            .cropped(to: extent)
    }

    private struct Configuration: Codable {
        let color: String?
        let intensity: Double?
    }

    private struct RGB {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        init?(hex: String) {
            let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard value.utf8.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
            red = CGFloat((rgb >> 16) & 0xFF) / 255
            green = CGFloat((rgb >> 8) & 0xFF) / 255
            blue = CGFloat(rgb & 0xFF) / 255
        }

        func polynomial(strength: CGFloat) -> [String: CIVector] {
            let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
            return [
                "inputRedCoefficients": coefficients(
                    for: red, luminance: luminance, strength: strength),
                "inputGreenCoefficients": coefficients(
                    for: green, luminance: luminance, strength: strength),
                "inputBlueCoefficients": coefficients(
                    for: blue, luminance: luminance, strength: strength),
                "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0)
            ]
        }

        private func coefficients(for channel: CGFloat, luminance: CGFloat, strength: CGFloat)
            -> CIVector
        {
            let offset = (channel - luminance) * strength * 4
            return CIVector(x: 0, y: 1 + offset, z: -offset, w: 0)
        }
    }
}

extension CGRect {
    fileprivate var isUsable: Bool {
        !isEmpty && !isInfinite && !isNull && origin.x.isFinite && origin.y.isFinite
            && width.isFinite && height.isFinite
    }
}

@MainActor extension MonochromeToneImageProcessor: Configurable {}
