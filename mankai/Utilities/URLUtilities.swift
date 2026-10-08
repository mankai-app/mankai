//
//  URLUtilities.swift
//  mankai
//
//  Created by Travis XU on 28/9/2026.
//

import CryptoKit
import Foundation

extension URL {
    /// Equivalent catalog or server URLs share an identity across installations.
    func stablePluginID(prefix: String) -> String {
        var normalizedURL = absoluteString

        if var components = URLComponents(url: self, resolvingAgainstBaseURL: false) {
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            components.user = nil
            components.password = nil
            components.fragment = nil

            if (components.scheme == "http" && components.port == 80)
                || (components.scheme == "https" && components.port == 443)
            {
                components.port = nil
            }

            normalizedURL = components.string ?? normalizedURL
        }

        let digest = SHA256.hash(data: Data(normalizedURL.utf8))

        return prefix + "-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedHost(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            !host.contains("/"), !host.contains("\\"), !host.contains("@"), !host.contains("\0")
        else { return nil }

        if host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 {
            return String(host.dropFirst().dropLast())
        }
        guard !host.hasPrefix("["), !host.hasSuffix("]") else { return nil }
        return host
    }

    static func isValidPort(_ port: Int) -> Bool { (1...65535).contains(port) }

    static func serverURL(scheme: String, host: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        guard let url = components.url, url.host?.isEmpty == false else { return nil }
        return url
    }

    static func normalizedHTTPURL(
        _ value: String, allowsCredentials: Bool = false, allowsQuery: Bool = false,
        allowsFragment: Bool = false, ensuresTrailingSlash: Bool = false
    ) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            components.host?.isEmpty == false,
            allowsCredentials || (components.user == nil && components.password == nil),
            allowsQuery || components.query == nil, allowsFragment || components.fragment == nil
        else { return nil }

        components.scheme = scheme
        if ensuresTrailingSlash, !components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "/"
        }
        return components.url
    }
}

/// Separates portable plugin settings from the server endpoint.
struct PluginURLConfiguration: Sendable {
    let baseURL: URL
    let configValues: [String: String]

    init?(_ value: String) {
        guard
            let url = URL.normalizedHTTPURL(
                value, allowsCredentials: true, allowsQuery: true, allowsFragment: true),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        var values: [String: String] = [:]

        if let username = components.user { values["username"] = username }
        if let password = components.password { values["password"] = password }

        for item in components.queryItems ?? [] { values[item.name] = item.value ?? "" }

        components.user = nil
        components.password = nil
        components.queryItems = nil
        components.fragment = nil

        guard let baseURL = components.url else { return nil }

        self.baseURL = baseURL
        configValues = values
    }

    func url(overriding values: [String: String]) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let values = configValues.merging(values) { _, updated in updated }
        components.queryItems =
            values.isEmpty
            ? nil
            : values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }

        return components.url
    }
}
