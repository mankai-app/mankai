//
//  FilesTab.swift
//  mankai
//
//  Created by Travis XU on 14/7/2026.
//

import SwiftUI

struct FilesTab: View {
    private enum Destination: Hashable {
        case share(String)
        case imports(UUID)
        case editShare(String)
    }

    @ObservedObject private var browseService = BrowseService.shared
    @Binding var importsNavigationID: UUID?
    var onImport: () -> Void
    @State private var path: [Destination] = []
    @State private var showingAddFilesModal = false
    @State private var removalError: String?
    @State private var sharePendingDeletion: BrowsablePlugin?

    init(importsNavigationID: Binding<UUID?>, onImport: @escaping () -> Void) {
        _importsNavigationID = importsNavigationID
        self.onImport = onImport
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(browseService.plugins, id: \.id) { share in
                        NavigationLink(value: Destination.share(share.id)) {
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
                        onImport()
                    } label: {
                        Label("import", systemImage: "square.and.arrow.down")
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
                    case .imports(let navigationID):
                        FilesScreen(
                            share: AppDirBrowsablePlugin.shared,
                            entry: AppDirBrowsablePlugin.shared.importsEntity
                        )
                        .id(navigationID)
                    case .editShare(let shareId):
                        if let share = browseService.getPlugin(shareId) {
                            ShareInfoScreen(share: share)
                        }
                }
            }
        }
        .onChange(of: importsNavigationID, initial: true) { _, navigationID in
            guard let navigationID else { return }
            path = [.imports(navigationID)]
            importsNavigationID = nil
        }
    }
}
