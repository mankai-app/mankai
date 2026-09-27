//
//  PluginInfoScreen.swift
//  mankai
//
//  Created by Travis XU on 26/6/2025.
//

import SwiftUI
import WrappingHStack

struct PluginInfoScreen: View {
    @ObservedObject var plugin: Plugin
    @AppStorage(SettingsKey.hideBuiltInPlugins.rawValue) private var hideBuiltInPlugins: Bool =
        SettingsDefaults.hideBuiltInPlugins

    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var errorTitle = ""

    @State private var showResetConfirmation = false
    @State private var showRemoveConfirmation = false

    @Environment(\.dismiss) private var dismiss

    private var supportedCapabilities: [PluginCapability] {
        PluginCapability.allCases.filter(plugin.supports)
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
                    LabeledContent("syncAcrossDevices") {
                        HStack(spacing: 8) {
                            Circle().fill(plugin.shouldSync ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(plugin.shouldSync ? "syncEnabled" : "syncDisabled")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if plugin is AppDirPlugin {
                    Section { Toggle("hideBuiltInPlugins", isOn: $hideBuiltInPlugins) }
                }

                if let configurable = plugin as? any Configurable, !configurable.configs.isEmpty {
                    Section("configs") { makeConfigView(configurable) }
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
                            "removePlugin", role: .destructive,
                            action: { showRemoveConfirmation = true }
                        )
                        .confirmationDialog(
                            "removePlugin", isPresented: $showRemoveConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("remove", role: .destructive) {
                                do {
                                    try PluginService.shared.removePlugin(plugin.id)
                                    dismiss()
                                } catch {
                                    errorTitle = String(localized: "failedToRemovePlugin")
                                    errorMessage = error.localizedDescription
                                    showErrorAlert = true
                                }
                            }
                            Button("cancel", role: .cancel) {}
                        } message: {
                            Text("removePluginConfirmation")
                        }
                    }
                }
            }
        }
        .navigationTitle(plugin.name ?? plugin.id)
        .alert(errorTitle, isPresented: $showErrorAlert) {
            Button("ok") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func makeConfigView<ConfigurableObject: Configurable & ObservableObject>(
        _ configurable: ConfigurableObject
    ) -> AnyView { AnyView(ConfigView(configurable: configurable)) }
}
