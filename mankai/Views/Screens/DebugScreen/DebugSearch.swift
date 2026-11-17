//
//  DebugSearch.swift
//  mankai
//
//  Created by Travis XU on 10/9/2026.
//

import SwiftUI

struct DebugSearch: View {
    let plugin: JsPlugin

    @State var mangas: [Manga]? = nil

    var body: some View {
        Group {
            if !plugin.supportsSearch() {
                DebugMethodNotSupported()
            } else if let mangas = mangas {
                List { DebugMangas(mangas: mangas, plugin: plugin) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard plugin.supportsSearch() else { return }
            mangas = try! await plugin.search(
                "mankai", page: 1, genre: .default, status: nil, isAuthor: false, sortBy: .default)
            Logger.jsPlugin.debug("mangas: \(mangas as Any)")
        }
        .navigationTitle("search")
    }
}
