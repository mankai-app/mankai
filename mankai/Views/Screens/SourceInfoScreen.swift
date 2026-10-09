//
//  SourceInfoScreen.swift
//  mankai
//
//  Created by Travis XU on 26/6/2025.
//

import SwiftUI
import WrappingHStack

struct SourceInfoScreen: View {
    @ObservedObject var plugin: Plugin
    @AppStorage(SettingsKey.hideBuiltInPlugins.rawValue) private var hideBuiltInPlugins: Bool =
        SettingsDefaults.hideBuiltInPlugins

    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var errorTitle = ""

    @State private var hasConfigChanges = false
    @State private var showResetConfirmation = false
    @State private var showRemoveConfirmation = false

    @Environment(\.dismiss) private var dismiss

    private var supportedCapabilities: [PluginCapability] {
        PluginCapability.allCases.filter(plugin.supports)
    }

    private var pluginSyncDisabledReason: LocalizedStringKey {
        if plugin is AppDirPlugin { return "syncSourceBuiltInDescription" }
        if plugin is ReadFsPlugin { return "syncSourceFilesystemDescription" }
        return "syncSourceMissingURLDescription"
    }

    private var mangaSyncDisabledReason: LocalizedStringKey {
        if plugin is AppDirPlugin { return "syncMangaBuiltInDescription" }
        return "syncMangaMissingIDDescription"
    }

    var body: some View {
        Group {
            List {
                Section("info") {
                    HStack {
                        Text("id")
                        Spacer()
                        Text(plugin.id).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }

                    if let name = plugin.name { LabeledContent("name") { Text(name) } }

                    if let version = plugin.version { LabeledContent("version") { Text(version) } }

                    if let description = plugin.description {
                        LabeledContent("description") { Text(description) }
                    }

                    if !plugin.authors.isEmpty {
                        LabeledContent("authors") { Text(plugin.authors.joined(separator: ", ")) }
                    }

                    if let repository = plugin.repository {
                        LabeledContent("repository") { Text(repository) }
                    }

                    if plugin.availableGenres.isEmpty {
                        LabeledContent("availableGenres") { Text("noGenresAvailable").italic() }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("availableGenres")
                            WrappingHStack(plugin.availableGenres, id: \.self, lineSpacing: 8) {
                                genre in Text(LocalizedStringKey(genre.rawValue)).genreTagStyle()
                            }
                        }
                    }

                    if supportedCapabilities.isEmpty {
                        LabeledContent("capabilities") { Text("none").italic() }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("capabilities")
                            WrappingHStack(supportedCapabilities, id: \.self, lineSpacing: 8) {
                                capability in
                                Text(LocalizedStringKey(capability.rawValue)).genreTagStyle()
                            }
                        }
                    }
                }

                Section("sync") {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("syncSourceAcrossDevices") {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(plugin.supports(.urlEncoding) ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(plugin.supports(.urlEncoding) ? "syncEnabled" : "syncDisabled")
                                    .foregroundColor(.secondary)
                            }
                        }

                        if !plugin.supports(.urlEncoding) {
                            Text(pluginSyncDisabledReason).font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("syncSourceDescription").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("syncMangaAcrossDevices") {
                            HStack(spacing: 8) {
                                Circle().fill(plugin.supports(.sync) ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(plugin.supports(.sync) ? "syncEnabled" : "syncDisabled")
                                    .foregroundColor(.secondary)
                            }
                        }

                        if !plugin.supports(.sync) {
                            Text(mangaSyncDisabledReason).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("syncMangaDescription").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if plugin is AppDirPlugin {
                    Section { Toggle("hideBuiltInSources", isOn: $hideBuiltInPlugins) }
                }

                if let configurable = plugin as? any Configurable & ObservableObject,
                    !configurable.configs.isEmpty
                {
                    Section("configs") { configView(for: configurable) }
                }

                if !(plugin is AppDirPlugin) {
                    Section("actions") {
                        if let configurable = plugin as? any Configurable,
                            !configurable.configs.isEmpty
                        {
                            Button(
                                "resetConfigs", role: .destructive,
                                action: { showResetConfirmation = true }
                            )
                            .confirmationDialog(
                                "resetConfigs", isPresented: $showResetConfirmation,
                                titleVisibility: .visible
                            ) {
                                Button("reset", role: .destructive) {
                                    do { try configurable.resetConfigs() } catch {
                                        errorTitle = String(localized: "failedToResetConfigs")
                                        errorMessage = error.localizedDescription
                                        showErrorAlert = true
                                    }
                                }
                                Button("cancel", role: .cancel) {}
                            } message: {
                                Text("resetConfigsConfirmation")
                            }
                        }

                        Button(
                            "removeSource", role: .destructive,
                            action: { showRemoveConfirmation = true }
                        )
                        .confirmationDialog(
                            "removeSource", isPresented: $showRemoveConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("remove", role: .destructive) {
                                do {
                                    try PluginService.shared.removePlugin(plugin.id)
                                    dismiss()
                                } catch {
                                    errorTitle = String(localized: "failedToRemoveSource")
                                    errorMessage = error.localizedDescription
                                    showErrorAlert = true
                                }
                            }
                            Button("cancel", role: .cancel) {}
                        } message: {
                            Text("removeSourceConfirmation")
                        }
                    }
                }
            }
        }
        .onReceive(plugin.objectWillChange) { _ in
            if plugin is any Configurable { hasConfigChanges = true }
        }
        .onDisappear { savePluginIfNeeded() }.navigationTitle(plugin.name ?? plugin.id)
        .alert(errorTitle, isPresented: $showErrorAlert) {
            Button("ok") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func savePluginIfNeeded() {
        guard hasConfigChanges, PluginService.shared.getPlugin(plugin.id) === plugin else { return }

        do {
            try PluginService.shared.savePlugin(plugin)
            hasConfigChanges = false
        } catch {
            Logger.pluginService.error(
                "Failed to save plugin configuration: \(plugin.id)", error: error)
            errorTitle = String(localized: "failedToSetConfigValue")
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }

    private func configView<ConfigurableObject: Configurable & ObservableObject>(
        for configurable: ConfigurableObject
    ) -> AnyView { AnyView(ConfigView(configurable: configurable)) }
}
