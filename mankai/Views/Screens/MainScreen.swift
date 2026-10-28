//
//  MainScreen.swift
//  mankai
//
//  Created by Travis XU on 20/6/2025.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MainScreen: View {
    private enum Tab: Hashable { case home, library, files, settings }

    @State private var selectedTab: Tab = .home
    @State private var showingFileImporter = false
    @State private var importsNavigationID: UUID?
    @State private var sourceImportRequest: SourceImportRequest?
    @State private var lastCheckedPasteboardChangeCount: Int?

    @AppStorage(SettingsKey.checkClipboard.rawValue) private var checkClipboard: Bool =
        SettingsDefaults.checkClipboard

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTab().tag(Tab.home).tabItem { Label("home", systemImage: "house") }
            LibraryTab().tag(Tab.library)
                .tabItem { Label("library", systemImage: "books.vertical.fill") }
            FilesTab(importsNavigationID: $importsNavigationID) { showingFileImporter = true }
                .tag(Tab.files).tabItem { Label("files", systemImage: "folder.fill") }
            SettingsTab().tag(Tab.settings).tabItem { Label("settings", systemImage: "gearshape") }
        }
        .overlay(alignment: .bottom) { NotificationContainerView() }
        .fileImporter(
            isPresented: $showingFileImporter, allowedContentTypes: supportedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result { case .success(let urls): importFiles(urls) case .failure(let error):
                showImportError(error)
            }
        }
        .sheet(item: $sourceImportRequest) { request in AddSourcesModal(sources: request.sources) }
        .onOpenURL { url in
            Logger.ui.info("Received URL: \(url)")

            if url.isFileURL {
                importFiles([url])
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

    private var supportedContentTypes: [UTType] {
        AppDirBrowsablePlugin.shared.supportedExtensions.compactMap { ext in
            if ext == "epub" { return .epub }
            return UTType(filenameExtension: ext)
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        do {
            for url in urls { try AppDirBrowsablePlugin.shared.importFile(from: url) }
            selectedTab = .files
            importsNavigationID = UUID()
        } catch { showImportError(error) }
    }

    private func showImportError(_ error: Error) {
        Logger.ui.error("Failed to import files", error: error)
        NotificationService.shared.showError(
            "\(String(localized: "failedToImport")): \(error.localizedDescription)")
    }

    private func handleMankaiURLs(_ urls: [URL]) {
        var sourceURLs: [URL] = []

        for url in urls {
            guard let host = url.host?.lowercased() else { continue }

            switch host { case "add-plugins": sourceURLs.append(url) default:
                Logger.ui.warning("Unsupported host: \(host)")
            }
        }

        guard !sourceURLs.isEmpty else { return }
        guard let request = SourceImportRequest(urls: sourceURLs) else {
            Logger.ui.warning("No source import URLs found")
            return
        }
        sourceImportRequest = request
    }
}
