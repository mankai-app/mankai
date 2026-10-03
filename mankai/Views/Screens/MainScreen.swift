//
//  MainScreen.swift
//  mankai
//
//  Created by Travis XU on 20/6/2025.
//

import SwiftUI
import UIKit

struct MainScreen: View {
    private enum Tab: Hashable { case home, library, browse, settings }

    @State private var selectedTab: Tab = .home
    @State private var importedFiles: [URL] = []
    @State private var showingImportsModal = false
    @State private var importDestinationPluginId: String?
    @State private var pluginImportRequest: PluginImportRequest?
    @State private var lastCheckedPasteboardChangeCount: Int?

    @AppStorage(SettingsKey.checkClipboard.rawValue) private var checkClipboard: Bool =
        SettingsDefaults.checkClipboard

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTab().tag(Tab.home).tabItem { Label("home", systemImage: "house") }
            LibraryTab().tag(Tab.library)
                .tabItem { Label("library", systemImage: "books.vertical.fill") }
            BrowseTab(importDestinationPluginId: $importDestinationPluginId) {
                showingImportsModal = true
            }
            .tag(Tab.browse).tabItem { Label("browse", systemImage: "folder.fill") }
            SettingsTab().tag(Tab.settings).tabItem { Label("settings", systemImage: "gearshape") }
        }
        .overlay(alignment: .bottom) { NotificationContainerView() }
        .sheet(isPresented: $showingImportsModal, onDismiss: { importedFiles = [] }) {
            [importedFiles] in
            ImportsModal(initialFiles: importedFiles) { plugin in
                importDestinationPluginId = plugin.id
            }
        }
        .sheet(item: $pluginImportRequest) { request in AddPluginsModal(sources: request.sources) }
        .onOpenURL { url in
            Logger.ui.info("Received URL: \(url)")

            if url.isFileURL {
                selectedTab = .browse
                importedFiles.append(url)
                showingImportsModal = true
                return
            }

            if url.scheme?.lowercased() == "mankai" { handleMankaiURLs([url]) }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            guard newPhase == .active else { return }
            guard checkClipboard else { return }

            let pasteboard = UIPasteboard.general
            let changeCount = pasteboard.changeCount

            guard lastCheckedPasteboardChangeCount != changeCount else { return }
            lastCheckedPasteboardChangeCount = changeCount

            var seenURLs = Set<URL>()
            let urls = pasteboard.items
                .flatMap { item in
                    item.values.compactMap { value -> URL? in
                        if let url = value as? URL { return url }

                        guard let value = value as? String else { return nil }
                        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        return URL(string: trimmedValue)
                    }
                }
                .filter { url in
                    guard url.scheme?.lowercased() == "mankai" else { return false }
                    return seenURLs.insert(url).inserted
                }

            guard !urls.isEmpty else { return }
            Logger.ui.info("Found \(urls.count) Mankai URL(s) in the pasteboard")
            handleMankaiURLs(urls)
        }
    }

    private func handleMankaiURLs(_ urls: [URL]) {
        var plugins: [PluginImportSource] = []

        for url in urls {
            guard let host = url.host?.lowercased() else { continue }

            switch host { case "add-plugins":
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let sources = (components?.queryItems ?? [])
                    .compactMap { item -> PluginImportSource? in
                        guard let type = PluginImportSource.Kind(rawValue: item.name.lowercased()),
                            let value = item.value, let decodedURL = Base62.decode(value),
                            let pluginURL = URL(string: decodedURL)
                        else { return nil }

                        return PluginImportSource(kind: type, url: pluginURL)
                    }

                guard !sources.isEmpty else {
                    Logger.ui.warning("No supported plugins found in URL: \(url)")
                    continue
                }

                plugins.append(contentsOf: sources)
                default: Logger.ui.warning("Unsupported host: \(host)")
            }
        }

        guard !plugins.isEmpty else { return }

        pluginImportRequest = PluginImportRequest(sources: plugins)
    }
}
