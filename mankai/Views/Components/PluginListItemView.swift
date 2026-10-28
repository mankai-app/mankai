//
//  PluginListItemView.swift
//  mankai
//
//  Created by Travis XU on 28/10/2026.
//

import SwiftUI
import WrappingHStack

struct PluginListItemView: View {
    @ObservedObject var plugin: Plugin

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                plugin.iconView

                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.name ?? plugin.id)

                    if !plugin.displayTags.isEmpty {
                        WrappingHStack(plugin.displayTags, id: \.self, lineSpacing: 4) { tag in
                            Text(tag).smallTagStyle()
                        }
                    }
                }
            }

            if let description = plugin.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
