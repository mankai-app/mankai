//
//  PathUtilities.swift
//  mankai
//
//  Created by Travis XU on 4/10/2026.
//

import Foundation

/// Validation and joining for slash-separated paths.
enum PathUtilities {
    static func isValidComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !value.contains("\0")
    }

    static func isValidAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/") else { return false }
        return hasValidPathComponents(String(value.dropFirst()))
    }

    static func isValidRelativePath(_ value: String) -> Bool {
        let firstComponent = value.prefix { $0 != "/" }
        guard !value.isEmpty, !value.hasPrefix("/"), !firstComponent.contains(":") else {
            return false
        }
        return hasValidPathComponents(value)
    }

    private static func hasValidPathComponents(_ value: String) -> Bool {
        guard !value.contains("\\") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { isValidComponent(String($0)) }
    }

    static func appending(_ relativePath: String, to rootPath: String) -> String {
        guard !rootPath.isEmpty else { return relativePath }
        let rootPath =
            rootPath == "/" ? "" : rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return "\(rootPath)/\(relativePath)"
    }
}
