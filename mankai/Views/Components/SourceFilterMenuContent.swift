//
//  SourceFilterMenuContent.swift
//  mankai
//
//  Created by Travis XU on 8/11/2026.
//

import SwiftUI

struct SourceFilterMenuContent: View {
    let plugin: Plugin
    let supportsGenreFilter: Bool
    let supportsCustomGenreFilter: Bool
    let supportsStatusFilter: Bool
    @Binding var genre: SourceGenreFilter
    @Binding var status: Status
    let onReset: () -> Void

    var body: some View {
        if supportsGenreFilter || supportsCustomGenreFilter {
            Picker("genre", selection: $genre) {
                Text("all").tag(SourceGenreFilter.standard(.all))
                if supportsGenreFilter {
                    ForEach(plugin.availableGenres.filter { $0 != .all }, id: \.self) { genre in
                        SourceGenreFilter.standard(genre).label
                            .tag(SourceGenreFilter.standard(genre))
                    }
                }
                if supportsCustomGenreFilter {
                    ForEach(plugin.availableCustomGenres, id: \.self) { genre in
                        SourceGenreFilter.custom(genre).label.tag(SourceGenreFilter.custom(genre))
                    }
                }
            }
            .pickerStyle(.menu)
        }

        if supportsStatusFilter {
            Picker("status", selection: $status) {
                Text(Status.any.localizedName).tag(Status.any)
                Text(Status.onGoing.localizedName).tag(Status.onGoing)
                Text(Status.completed.localizedName).tag(Status.completed)
            }
            .pickerStyle(.menu)
        }

        Section { Button("reset", role: .destructive, action: onReset) }
    }
}
