//
//  PluginInfoView.swift
//  mankai
//
//  Created by Travis XU on 28/10/2026.
//

import SwiftUI
import WrappingHStack

struct PluginInfoView: View {
    @ObservedObject var plugin: Plugin

    private var websiteURL: URL? {
        [plugin.homePage, plugin.repository].compactMap { $0 }
            .compactMap { URL.normalizedHTTPURL($0, allowsQuery: true, allowsFragment: true) }.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                plugin.iconView.scaleEffect(2).frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.name ?? plugin.id).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)

                    if !plugin.displayTags.isEmpty {
                        WrappingHStack(plugin.displayTags, id: \.self, lineSpacing: 4) { tag in
                            Text(tag).smallTagStyle()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let websiteURL {
                    Link(destination: websiteURL) { Image(systemName: "arrow.up.right.square") }
                }
            }

            if let description = plugin.description, !description.isEmpty {
                Text(description).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
