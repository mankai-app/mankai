//
//  FilterButton.swift
//  mankai
//
//  Created by Travis XU on 4/10/2026.
//

import SwiftUI

struct FilterButton: View {
    let hasActiveFilters: Bool
    let action: () -> Void

    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) {
            Toggle(isOn: Binding(get: { hasActiveFilters }, set: { _ in action() })) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(hasActiveFilters ? .white : .primary)
            }
        } else {
            Button(action: action) {
                Image(
                    systemName: hasActiveFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
            }
        }
    }
}
