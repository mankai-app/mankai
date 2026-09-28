//
//  URLUtilities.swift
//  mankai
//
//  Created by Travis XU on 28/9/2026.
//

import Foundation

extension URL {
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
