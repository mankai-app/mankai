//
//  SourceImportRequest.swift
//  mankai
//
//  Created by Travis XU on 9/10/2026.
//

import Foundation

struct SourceImportItem: Identifiable, Hashable {
    let id = UUID()
    let type: String
    let url: URL
}

struct SourceImportRequest: Identifiable, Hashable {
    let id = UUID()
    let sources: [SourceImportItem]

    init?(link: String) {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: link) else { return nil }
        self.init(urls: [url])
    }

    init?(urls: [URL]) {
        let sources = urls.flatMap { url -> [SourceImportItem] in
            guard url.scheme?.lowercased() == "mankai", url.host?.lowercased() == "add-plugins",
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return [] }

            return (components.queryItems ?? [])
                .compactMap { item in
                    guard let value = item.value, let decodedURL = Base62.decode(value),
                        let pluginURL = URL(string: decodedURL), pluginURL.scheme != nil
                    else { return nil }

                    return SourceImportItem(type: item.name.lowercased(), url: pluginURL)
                }
        }

        guard !sources.isEmpty else { return nil }
        self.sources = sources
    }
}
