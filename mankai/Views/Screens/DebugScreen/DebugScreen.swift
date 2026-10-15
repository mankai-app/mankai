//
//  DebugScreen.swift
//  mankai
//
//  Created by Travis XU on 24/6/2025.
//

import SwiftUI

struct DebugScreen: View {
    @State var plugin: JsPlugin?
    @State private var jsonInput: String = ""
    @State private var isError: Bool = false

    var body: some View {
        List {
            if let plugin = plugin {
                Section("info") {
                    LabeledContent("id") { Text(plugin.id) }
                    LabeledContent("name") { Text(plugin.name ?? String(localized: "nil")) }
                    LabeledContent("version") { Text(plugin.version ?? String(localized: "nil")) }
                    LabeledContent("description") {
                        Text(plugin.description ?? String(localized: "nil"))
                    }
                    LabeledContent("authors") {
                        Text(
                            plugin.authors.isEmpty
                                ? String(localized: "nil") : plugin.authors.joined(separator: ", "))
                    }
                    LabeledContent("repository") {
                        Text(plugin.repository ?? String(localized: "nil"))
                    }
                    LabeledContent {
                        Text(plugin.updatesUrl ?? String(localized: "nil"))
                    } label: {
                        Text(verbatim: "updatesUrl")
                    }
                }

                Section("availableGenres") {
                    if plugin.availableGenres.isEmpty {
                        Text("noGenresAvailable").foregroundColor(.secondary).italic()
                    } else {
                        ForEach(plugin.availableGenres, id: \.self) { genre in
                            Text(LocalizedStringKey(genre.rawValue))
                        }
                    }
                }

                Section("configs") {
                    if plugin.configs.isEmpty {
                        Text("noConfig").foregroundColor(.secondary).italic()
                    } else {
                        ForEach(plugin.configs.indices, id: \.self) { index in
                            let config = plugin.configs[index]

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(config.name).font(.headline)
                                    Spacer()
                                    Text(LocalizedStringKey(config.type.rawValue)).smallTagStyle()
                                }

                                if let description = config.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }

                                HStack {
                                    Text("key").font(.caption).foregroundStyle(.secondary)
                                    Text(config.key).font(.caption).fontDesign(.monospaced)
                                }

                                HStack {
                                    Text("default").font(.caption).foregroundStyle(.secondary)
                                    Text(String(describing: config.defaultValue)).font(.caption)
                                        .fontDesign(.monospaced)
                                }

                                if let options = config.options {
                                    HStack {
                                        Text("option").font(.caption).foregroundStyle(.secondary)
                                        Text(String(describing: options)).font(.caption)
                                            .fontDesign(.monospaced)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("methods") {
                    NavigationLink(destination: DebugIsOnline(plugin: plugin)) {
                        Text(verbatim: "isOnline")
                    }

                    NavigationLink(destination: DebugGetSuggestion(plugin: plugin)) {
                        Text(verbatim: "getSuggestion")
                    }

                    NavigationLink(destination: DebugSearch(plugin: plugin)) { Text("search") }

                    NavigationLink(destination: DebugGetList(plugin: plugin)) {
                        Text(verbatim: "getList")
                    }

                    Text(verbatim: "getMangas")

                    Text(verbatim: "getMangaUpdates")

                    Text(verbatim: "getDetailedManga")

                    Text(verbatim: "getChapter")

                    Text(verbatim: "getImage")
                }

            } else {
                Section("jsPlugin") {
                    TextField("json", text: $jsonInput)
                    Button("parse") {
                        plugin = jsonInput.data(using: .utf8)
                            .flatMap {
                                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                            }
                            .flatMap { JsPlugin.fromJson($0) }
                        if plugin == nil { isError = true }
                    }
                    .alert("error", isPresented: $isError) { Button("ok", role: .cancel) {} }
                }
            }
        }
        .navigationTitle("debug").navigationBarTitleDisplayMode(.inline)
    }
}
