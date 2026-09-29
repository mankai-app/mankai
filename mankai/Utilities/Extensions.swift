//
//  Extensions.swift
//  mankai
//
//  Created by Travis XU on 27/6/2025.
//

import CoreGraphics
import SwiftUI
import UIKit

extension UIApplication {
    static var windowBounds: CGRect {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?
            .bounds ?? UIScreen.main.bounds
    }

    static var statusBarHeight: CGFloat? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        let window = windowScene?.windows.first

        return window?.windowScene?.statusBarManager?.statusBarFrame.height
    }
}

extension Optional where Wrapped == Status {
    var localizedName: String { self?.localizedName ?? String(localized: "nil") }
}

extension UIDevice {
    static var isIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    static var isIPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    static var isDuo: Bool { UserDefaults.standard.bool(forKey: SettingsKey.isDuo.rawValue) }
}

enum ImageFormat: String {
    case unknown
    case png
    case jpeg = "jpg"
    case gif
    case tiff
    case webp

    var mimeType: String {
        switch self { case .png: return "image/png" case .jpeg: return "image/jpeg" case .gif:
            return "image/gif"
            case .tiff: return "image/tiff"
            case .webp: return "image/webp"
            case .unknown: return "application/octet-stream"
        }
    }
}

extension Data {
    var imageFormat: ImageFormat {
        guard count >= 4 else { return .unknown }

        var header = [UInt8](repeating: 0, count: 4)
        copyBytes(to: &header, count: 4)

        switch header {
            case let h where h[0] == 0x89 && h[1] == 0x50 && h[2] == 0x4E && h[3] == 0x47:
                return .png
            case let h where h[0] == 0xFF && h[1] == 0xD8: return .jpeg
            case let h where h[0] == 0x47 && h[1] == 0x49 && h[2] == 0x46: return .gif
            case let h where h[0] == 0x49 || h[0] == 0x4D: return .tiff
            case let h where h[0] == 0x52 && h[1] == 0x49 && h[2] == 0x46 && h[3] == 0x46:
                return .webp
            default: return .unknown
        }
    }

    func detectImageMimeType() -> String { imageFormat.mimeType }
}

extension NSData { var imageFormat: ImageFormat { (self as Data).imageFormat } }

extension Optional where Wrapped == String {
    var trimmed: String? {
        guard let self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Color {
    /// Creates an sRGB color from #RRGGBB or #RRGGBBAA.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.utf8.count == 6 || value.utf8.count == 8,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }), let rgba = UInt32(value, radix: 16)
        else { return nil }

        let hasAlpha = value.utf8.count == 8
        let rgb = hasAlpha ? rgba >> 8 : rgba
        let alpha = hasAlpha ? Double(rgba & 0xFF) / 255 : 1
        self.init(
            .sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255, opacity: alpha)
    }

    @MainActor var hex: String? { hex(includingAlpha: false) }

    /// Encodes a configuration color as #RRGGBB or #RRGGBBAA.
    @MainActor func hex(includingAlpha: Bool = false) -> String? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = UIColor(self).cgColor
                .converted(to: colorSpace, intent: .defaultIntent, options: nil),
            let components = converted.components, components.count == 4,
            components.allSatisfy({ $0.isFinite })
        else { return nil }

        let channels = components.prefix(3).map { UInt32((min(max($0, 0), 1) * 255).rounded()) }
        let rgb = (channels[0] << 16) | (channels[1] << 8) | channels[2]
        guard includingAlpha else { return String(format: "#%06X", rgb) }

        let alpha = UInt32((min(max(components[3], 0), 1) * 255).rounded())
        return String(format: "#%06X%02X", rgb, alpha)
    }
}
