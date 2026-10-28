//
//  GeneralSettingsScreen.swift
//  mankai
//
//  Created by Travis XU on 12/7/2025.
//

import SwiftUI

private func formattedCacheSize(for directoryName: String) -> String? {
    let fileManager = FileManager.default
    guard let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }

    let directory = cacheDirectory.appendingPathComponent(directoryName)
    let size = (try? fileManager.allocatedSizeOfDirectory(at: directory)) ?? 0

    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useAll]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(size))
}

private func clearCacheContents(in directoryName: String) {
    let fileManager = FileManager.default
    guard let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return }

    let directory = cacheDirectory.appendingPathComponent(directoryName)
    guard fileManager.fileExists(atPath: directory.path) else { return }

    do {
        let contents = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        for url in contents { try fileManager.removeItem(at: url) }
    } catch { Logger.ui.error("Failed to clear cache: \(error)") }
}

struct GeneralSettingsScreen: View {
    @AppStorage(SettingsKey.inMemoryCacheItemCount.rawValue) private var inMemoryCacheItemCount:
        Int = SettingsDefaults.inMemoryCacheItemCount
    @AppStorage(SettingsKey.diskCacheSizeLimit.rawValue) private var diskCacheSizeLimitRawValue:
        Int = SettingsDefaults.diskCacheSizeLimit.rawValue
    @AppStorage(SettingsKey.showDebugScreen.rawValue) private var showDebugScreen: Bool =
        SettingsDefaults.showDebugScreen
    @AppStorage(SettingsKey.checkClipboard.rawValue) private var checkClipboard: Bool =
        SettingsDefaults.checkClipboard
    @ObservedObject private var updateService = UpdateService.shared
    @State private var cacheSize: String = ""
    @State private var indexCacheSize: String = ""
    @State private var showClearCacheAlert = false
    @State private var showClearIndexCacheAlert = false

    var body: some View {
        List {
            Section { Toggle("checkClipboard", isOn: $checkClipboard) }

            Section("libraryUpdates") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("lastUpdateTime") {
                        if let progress = updateService.progress {
                            if progress.total > 0 {
                                Text(verbatim: "\(progress.completed)/\(progress.total)")
                                    .monospacedDigit().foregroundColor(.secondary)
                            } else {
                                ProgressView()
                            }
                        } else if let lastUpdateTime = updateService.lastUpdateTime {
                            Text(lastUpdateTime, style: .relative).foregroundColor(.secondary)
                        } else {
                            Text("never").foregroundColor(.secondary)
                        }
                    }

                    if let progress = updateService.progress, progress.total > 0 {
                        ProgressView(value: progress.fractionCompleted)
                    }
                }
            }

            Section {
                Picker("inMemoryCacheItemCount", selection: $inMemoryCacheItemCount) {
                    Text(verbatim: "25").tag(25)
                    Text(verbatim: "50").tag(50)
                    Text(verbatim: "100").tag(100)
                    Text(verbatim: "250").tag(250)
                    Text(verbatim: "500").tag(500)
                }

                Picker(
                    "cacheSizeLimit",
                    selection: Binding(
                        get: {
                            DiskCacheLimit(rawValue: diskCacheSizeLimitRawValue)
                                ?? SettingsDefaults.diskCacheSizeLimit
                        }, set: { diskCacheSizeLimitRawValue = $0.rawValue })
                ) {
                    Text(DiskCacheLimit.fiveHundredMB.localizedName)
                        .tag(DiskCacheLimit.fiveHundredMB)
                    Text(DiskCacheLimit.oneGB.localizedName).tag(DiskCacheLimit.oneGB)
                    Text(DiskCacheLimit.twoGB.localizedName).tag(DiskCacheLimit.twoGB)
                    Text(DiskCacheLimit.fiveGB.localizedName).tag(DiskCacheLimit.fiveGB)
                    Text(DiskCacheLimit.tenGB.localizedName).tag(DiskCacheLimit.tenGB)
                }

                LabeledContent("cacheSize") {
                    Button(role: .destructive) {
                        showClearCacheAlert = true
                    } label: {
                        if cacheSize.isEmpty {
                            ProgressView()
                        } else {
                            HStack(spacing: 4) {
                                Text(cacheSize)
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
                .confirmationDialog(
                    "clearCache", isPresented: $showClearCacheAlert, titleVisibility: .visible
                ) {
                    Button("clear", role: .destructive) { clearCache() }
                    Button("cancel", role: .cancel) {}
                } message: {
                    Text("clearCacheMessage")
                }

                LabeledContent("indexSize") {
                    Button(role: .destructive) {
                        showClearIndexCacheAlert = true
                    } label: {
                        if indexCacheSize.isEmpty {
                            ProgressView()
                        } else {
                            HStack(spacing: 4) {
                                Text(indexCacheSize)
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
                .confirmationDialog(
                    "clearIndex", isPresented: $showClearIndexCacheAlert, titleVisibility: .visible
                ) {
                    Button("clear", role: .destructive) { clearIndexCache() }
                    Button("cancel", role: .cancel) {}
                } message: {
                    Text("clearIndexMessage")
                }
            } header: {
                Text("storageAndPerformance")
            } footer: {
                Text("cacheDescription")
            }

            Section("about") {
                LabeledContent("version") { Text(appVersion) }

                NavigationLink {
                    AppLicenseScreen()
                } label: {
                    LabeledContent("license") { Text(verbatim: "GNU GPLv3") }
                }

                NavigationLink("thirdPartyLicenses") { ThirdPartyLicensesScreen() }
            }

            Section("developer") { Toggle("showDebugScreen", isOn: $showDebugScreen) }
        }
        .navigationTitle("general").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            updateCacheSize()
            updateIndexCacheSize()
        }
    }

    private var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        {
            return "\(version) (\(build))"
        } else if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        {
            return version
        } else {
            return String(localized: "nil")
        }
    }

    private func updateCacheSize() {
        Task { @MainActor in
            let formattedSize =
                await Task.detached(priority: .userInitiated) {
                    formattedCacheSize(for: CacheDirectory.regular)
                }
                .value
            guard let formattedSize else { return }

            cacheSize = formattedSize
        }
    }

    private func updateIndexCacheSize() {
        Task { @MainActor in
            let formattedSize =
                await Task.detached(priority: .userInitiated) {
                    formattedCacheSize(for: CacheDirectory.index)
                }
                .value
            guard let formattedSize else { return }

            indexCacheSize = formattedSize
        }
    }

    private func clearCache() {
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                clearCacheContents(in: CacheDirectory.regular)
            }
            .value

            updateCacheSize()
        }
    }

    @MainActor private func clearIndexCache() {
        DbService.shared.closeBrowsablePluginDb()
        DbService.shared.closeOpdsBrowsablePluginDb()

        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                clearCacheContents(in: CacheDirectory.index)
            }
            .value

            updateIndexCacheSize()
        }
    }
}
