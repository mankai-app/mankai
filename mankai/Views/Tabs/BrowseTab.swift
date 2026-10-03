//
//  BrowseTab.swift
//  mankai
//
//  Created by Travis XU on 14/7/2026.
//

import SwiftUI

struct BrowseTab: View {
    @ObservedObject private var browseService = BrowseService.shared
    @Binding var importDestinationPluginId: String?
    var onShowImports: () -> Void
    @State private var showingAddFolderModal = false
    @State private var importError: String?
    @State private var pluginPendingDeletion: BrowsablePlugin?
    @State private var editDestinationPluginId: String?

    init(importDestinationPluginId: Binding<String?>, onShowImports: @escaping () -> Void) {
        _importDestinationPluginId = importDestinationPluginId
        self.onShowImports = onShowImports
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(browseService.plugins, id: \.id) { plugin in
                        NavigationLink {
                            BrowseScreen(plugin: plugin)
                        } label: {
                            Label {
                                Text(plugin.name ?? plugin.id)
                            } icon: {
                                plugin.icon
                            }
                            .labelStyle(ColorfulIconLabelStyle(color: plugin.color))
                        }
                        .deleteDisabled(plugin is AppDirBrowsablePlugin)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if !(plugin is AppDirBrowsablePlugin) {
                                Button {
                                    editDestinationPluginId = plugin.id
                                } label: {
                                    Label("edit", systemImage: "pencil")
                                }
                                .tint(.blue).labelStyle(.iconOnly)
                            }
                        }
                    }
                    .onDelete { offsets in
                        guard let index = offsets.first,
                            browseService.plugins.indices.contains(index)
                        else { return }
                        let plugin = browseService.plugins[index]
                        guard !(plugin is AppDirBrowsablePlugin) else { return }
                        pluginPendingDeletion = plugin
                    }

                    Button {
                        showingAddFolderModal = true
                    } label: {
                        Label("addFolder", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("swipeToEditOrRemoveFolder")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onShowImports()
                    } label: {
                        Label("imports", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .navigationTitle("browse")
            .alert(
                "failedToAddFolder",
                isPresented: .init(
                    get: { importError != nil }, set: { if !$0 { importError = nil } })
            ) {
                Button("ok", role: .cancel) {}
            } message: {
                if let importError { Text(importError) }
            }
            .confirmationDialog(
                "removeFolder",
                isPresented: .init(
                    get: { pluginPendingDeletion != nil },
                    set: { if !$0 { pluginPendingDeletion = nil } }), titleVisibility: .visible
            ) {
                Button("remove", role: .destructive) {
                    if let plugin = pluginPendingDeletion {
                        do { try browseService.removePlugin(plugin.id) } catch {
                            importError = error.localizedDescription
                        }
                        pluginPendingDeletion = nil
                    }
                }
                Button("cancel", role: .cancel) { pluginPendingDeletion = nil }
            } message: {
                Text("removeFolderConfirmation")
            }
            .sheet(isPresented: $showingAddFolderModal) { AddBrowsableFolderModal() }
            .navigationDestination(item: $importDestinationPluginId) { pluginId in
                if let plugin = browseService.getImportablePlugin(pluginId) {
                    BrowseScreen(plugin: plugin, entry: plugin.importsEntity)
                }
            }
            .navigationDestination(item: $editDestinationPluginId) { pluginId in
                if let plugin = browseService.plugins.first(where: { $0.id == pluginId }) {
                    FolderInfoScreen(plugin: plugin)
                }
            }
        }
    }
}
