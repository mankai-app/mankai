//
//  SourceFilterMenuContent.swift
//  mankai
//
//  Created by Travis XU on 8/11/2026.
//

import SwiftUI

extension SourceGenre {
    var label: Text {
        switch self { case .default: Text("all") case .standard(let genre):
            Text(LocalizedStringKey(genre.rawValue))
            case .custom(let name): Text(verbatim: name)
        }
    }
}

extension SourceSort {
    fileprivate var label: Text {
        switch self { case .default: Text("default") case .updateTime: Text("sortByUpdateTime")
            case .popularity: Text("popularity")
            case .custom(let name): Text(verbatim: name)
        }
    }
}

struct SourceFilterMenuContent: View {
    let genreOptions: [SourceGenre]
    let supportsStatusFilter: Bool
    let sortOptions: [SourceSort]
    @Binding var genre: SourceGenre
    @Binding var status: SourceStatusFilter?
    @Binding var sortBy: SourceSort
    let onReset: () -> Void

    var body: some View {
        if genreOptions.count > 1 || genre != .default {
            Picker("genre", selection: $genre) {
                ForEach(genreOptions, id: \.self) { option in option.label.tag(option) }
                if !genreOptions.contains(genre) { genre.label.tag(genre) }
            }
            .pickerStyle(.menu)
        }

        if supportsStatusFilter {
            Picker("status", selection: $status) {
                Text("any").tag(nil as SourceStatusFilter?)
                ForEach(SourceStatusFilter.allCases, id: \.self) { status in
                    Text(status.mangaStatus.localizedName).tag(status as SourceStatusFilter?)
                }
            }
            .pickerStyle(.menu)
        }

        if sortOptions.count > 1 {
            Picker("sortBy", selection: $sortBy) {
                ForEach(sortOptions, id: \.self) { option in option.label.tag(option) }
            }
            .pickerStyle(.menu)
        }

        Section { Button("reset", role: .destructive, action: onReset) }
    }
}
