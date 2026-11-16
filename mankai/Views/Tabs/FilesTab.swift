//
//  FilesTab.swift
//  mankai
//
//  Created by Travis XU on 14/7/2026.
//

import SwiftUI

struct FilesTab: View {
    enum Destination: Hashable {
        case share(String)
        case folder(shareID: String, entry: Entity, id: UUID = UUID())
        case editShare(String)
    }

    @ObservedObject private var browseService = BrowseService.shared
    @Binding var requestedDestination: Destination?
    var onImport: () -> Void
    @State private var path: [Destination] = []
    @State private var showingAddFilesModal = false
    @State private var removalError: String?
    @State private var sharePendingDeletion: BrowsablePlugin?

    init(requestedDestination: Binding<Destination?>, onImport: @escaping () -> Void) {
        _requestedDestination = requestedDestination
        self.onImport = onImport
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(browseService.plugins, id: \.id) { share in
                        NavigationLink(value: Destination.share(share.id)) {
                            HStack(spacing: 12) {
                                share.iconView
                                Text(share.name ?? share.id)
                            }
                        }
                        .deleteDisabled(share is AppDirBrowsablePlugin)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if !(share is AppDirBrowsablePlugin) {
                                Button {
                                    path.append(.editShare(share.id))
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
                } footer: {
                    Text("swipeToEditOrRemoveShare")
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onImport()
                    } label: {
                        Label("import", systemImage: "square.and.arrow.down")
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingAddFilesModal = true }) {
                        ToolbarIcon(systemName: "plus", legacySystemName: "plus.circle")
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
            .navigationDestination(for: Destination.self) { destination in
                switch destination { case .share(let shareId):
                    if let share = browseService.getPlugin(shareId) { FilesScreen(share: share) }
                    case .folder(let shareID, let entry, let id):
                        if let share = browseService.plugins.first(where: { $0.id == shareID }) {
                            FilesScreen(share: share, entry: entry).id(id)
                        }
                    case .editShare(let shareId):
                        if let share = browseService.getPlugin(shareId) {
                            ShareInfoScreen(share: share)
                        }
                }
            }
        }
        .onChange(of: requestedDestination, initial: true) { _, destination in
            guard let destination else { return }
            path = [destination]
            requestedDestination = nil
        }
    }
}
