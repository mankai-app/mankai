//
//  PluginSettingsScreen.swift
//  mankai
//
//  Created by Travis XU on 21/6/2025.
//

import SwiftUI

struct PluginSettingsScreen: View {
    @State private var showModal = false
    @State private var showingRemoveConfirmation = false
    @State private var pluginIdsToRemove: [String] = []
    @State private var errorMessage: String?
    @ObservedObject var pluginService: PluginService = .shared

    private var sortedPlugins: [Plugin] {
        pluginService.plugins.sorted { plugin1, plugin2 in
            let isPlugin1AppFs = plugin1 is AppDirPlugin
            let isPlugin2AppFs = plugin2 is AppDirPlugin

            if isPlugin1AppFs, !isPlugin2AppFs {
                return true
            } else if !isPlugin1AppFs, isPlugin2AppFs {
                return false
            } else {
                return plugin1.name ?? plugin1.id < plugin2.name ?? plugin2.id
            }
        }
    }

    var body: some View {
        List {
            SettingsHeaderView(
                image: Image(systemName: "square.stack.3d.up.fill"), color: .red,
                title: String(localized: "plugins"),
                description: String(localized: "pluginsDescription"))

            ForEach(sortedPlugins) { plugin in
                NavigationLink(destination: { PluginInfoScreen(plugin: plugin) }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(plugin.name ?? plugin.id)

                            ForEach(plugin.tags, id: \.self) { tag in Text(tag).smallTagStyle() }

                            if let version = plugin.version {
                                Text(verbatim: "v\(version)").smallTagStyle()
                            }

                            if plugin is Editable,
                                !plugin.tags.contains(String(localized: "editable"))
                            {
                                Text("editable").smallTagStyle()
                            }
                        }
                        if let description = plugin.description {
                            Text(description).font(.caption).foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .deleteDisabled(plugin is AppDirPlugin)
            }
            .onDelete { offsets in
                let plugins = sortedPlugins
                pluginIdsToRemove = offsets.compactMap { index in
                    let plugin = plugins[index]
                    return plugin is AppDirPlugin ? nil : plugin.id
                }
                showingRemoveConfirmation = !pluginIdsToRemove.isEmpty
            }
        }
        .toolbar {
            if sortedPlugins.contains(where: { !($0 is AppDirPlugin) }) {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showModal = true }) {
                    ToolbarIcon(systemName: "plus", legacySystemName: "plus.circle")
                }
            }
        }
        .navigationTitle("plugins").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showModal) { AddPluginModal() }
        .confirmationDialog(
            "removePlugin", isPresented: $showingRemoveConfirmation, titleVisibility: .visible
        ) {
            Button("remove", role: .destructive) {
                let ids = pluginIdsToRemove
                pluginIdsToRemove = []
                for id in ids {
                    do { try pluginService.removePlugin(id) } catch {
                        errorMessage = error.localizedDescription
                        break
                    }
                }
            }
            Button("cancel", role: .cancel) { pluginIdsToRemove = [] }
        } message: {
            if pluginIdsToRemove.count == 1 {
                Text("removePluginConfirmation")
            } else {
                Text("removePluginsConfirmation")
            }
        }
        .alert(
            "failedToRemovePlugin",
            isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("ok", role: .cancel) { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }
}
