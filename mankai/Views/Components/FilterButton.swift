//
//  FilterButton.swift
//  mankai
//
//  Created by Travis XU on 4/10/2026.
//

import SwiftUI

struct FilterButton<MenuContent: View>: View {
    let hasActiveFilters: Bool
    let menu: MenuContent

    var body: some View {
        if #available(iOS 26.0, *) {
            Toggle(isOn: .constant(hasActiveFilters)) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(hasActiveFilters ? .white : .primary)
            }
            .overlay {
                Menu {
                    menu
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            }
        } else {
            Menu {
                menu
            } label: {
                Image(
                    systemName: hasActiveFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
            }
            .menuIndicator(.hidden)
        }
    }
}
