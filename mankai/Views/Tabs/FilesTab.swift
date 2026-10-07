//
//  FilesTab.swift
//  mankai
//
//  Created by Travis XU on 14/7/2026.
//

import SwiftUI

struct FilesTab: View {
    @ObservedObject private var browseService = BrowseService.shared
    @Binding var importDestinationShareId: String?
    var onShowImports: () -> Void
    @State private var showingAddFilesModal = false
    @State private var removalError: String?
    @State private var sharePendingDeletion: BrowsablePlugin?
    @State private var editDestinationShareId: String?

    init(importDestinationShareId: Binding<String?>, onShowImports: @escaping () -> Void) {
        _importDestinationShareId = importDestinationShareId
        self.onShowImports = onShowImports
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(browseService.plugins, id: \.id) { share in
                        NavigationLink {
                            FilesScreen(share: share)
                        } label: {
                            Label {
                                Text(share.name ?? share.id)
                            } icon: {
                                share.icon
                            }
                            .labelStyle(ColorfulIconLabelStyle(color: share.color))
                        }
                        .deleteDisabled(share is AppDirBrowsablePlugin)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if !(share is AppDirBrowsablePlugin) {
                                Button {
                                    editDestinationShareId = share.id
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
                        let share = browseService.plugins[index]
                        guard !(share is AppDirBrowsablePlugin) else { return }
                        sharePendingDeletion = share
                    }

                    Button {
                        showingAddFilesModal = true
                    } label: {
                        Label("addFiles", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("swipeToEditOrRemoveShare")
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
            .navigationTitle("files")
            .alert(
                "failedToRemoveShare",
                isPresented: .init(
                    get: { removalError != nil }, set: { if !$0 { removalError = nil } })
            ) {
                Button("ok", role: .cancel) {}
            } message: {
                if let removalError { Text(removalError) }
            }
            .confirmationDialog(
                "removeShare",
                isPresented: .init(
                    get: { sharePendingDeletion != nil },
                    set: { if !$0 { sharePendingDeletion = nil } }), titleVisibility: .visible
            ) {
                Button("remove", role: .destructive) {
                    if let share = sharePendingDeletion {
                        do { try browseService.removePlugin(share.id) } catch {
                            removalError = error.localizedDescription
                        }
                        sharePendingDeletion = nil
                    }
                }
                Button("cancel", role: .cancel) { sharePendingDeletion = nil }
            } message: {
                Text("removeShareConfirmation")
            }
            .sheet(isPresented: $showingAddFilesModal) { AddFilesModal() }
            .navigationDestination(item: $importDestinationShareId) { shareId in
                if let share = browseService.getImportablePlugin(shareId) {
                    FilesScreen(share: share, entry: share.importsEntity)
                }
            }
            .navigationDestination(item: $editDestinationShareId) { shareId in
                if let share = browseService.plugins.first(where: { $0.id == shareId }) {
                    ShareInfoScreen(share: share)
                }
            }
        }
    }
}
