//
//  PluginIconView.swift
//  mankai
//
//  Created by Travis XU on 28/10/2026.
//

import SwiftUI

struct PluginIconView: View {
    var icon: String? = nil
    let defaultIcon: PluginIcon
    let color: Color

    private var iconURL: URL? {
        icon.flatMap { URL.normalizedHTTPURL($0, allowsQuery: true, allowsFragment: true) }
    }

    var body: some View {
        Group {
            if let url = iconURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.renderingMode(.original).resizable().scaledToFill()
                    } else {
                        defaultIconView
                    }
                }
            } else {
                defaultIconView
            }
        }
        .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 7)).fixedSize()
    }

    private var defaultIconView: some View {
        defaultIcon.view(color: color).foregroundStyle(.white).frame(width: 28, height: 28)
            .background(color)
    }
}
