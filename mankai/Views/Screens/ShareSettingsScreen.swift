//
//  ShareSettingsScreen.swift
//  mankai
//
//  Created by Travis XU on 20/8/2026.
//

import SwiftUI

struct ShareSettingsScreen: View {
    @ObservedObject private var browseService = BrowseService.shared
    @State private var showingAddFilesModal = false
    @State private var showingRemoveConfirmation = false
    @State private var shareIdsToRemove: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            SettingsHeaderView(
                image: Image(systemName: "folder.fill"), color: .blue,
                title: String(localized: "shares"),
                description: String(localized: "sharesDescription"))

            ForEach(browseService.plugins, id: \.id) { share in
                NavigationLink {
                    ShareInfoScreen(share: share)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(share.name ?? share.id)

                            HStack(spacing: 8) {
                                Text(shareTypeName(for: share)).smallTagStyle()

                                if share is AppDirBrowsablePlugin {
                                    Text("builtin").smallTagStyle()
                                }
                            }
                        }
                    } icon: {
                        share.icon
                    }
                    .labelStyle(ColorfulIconLabelStyle(color: share.color))
                }
                .deleteDisabled(share is AppDirBrowsablePlugin)
            }
            .onDelete { offsets in
                let shares = browseService.plugins
                shareIdsToRemove = offsets.compactMap { index in
                    let share = shares[index]
                    return share is AppDirBrowsablePlugin ? nil : share.id
                }
                showingRemoveConfirmation = !shareIdsToRemove.isEmpty
            }
        }
        .toolbar {
            if browseService.plugins.contains(where: { !($0 is AppDirBrowsablePlugin) }) {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddFilesModal = true
                } label: {
                    ToolbarIcon(systemName: "plus", legacySystemName: "plus.circle")
                }
            }
        }
        .navigationTitle("shares").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddFilesModal) { AddFilesModal() }
        .confirmationDialog(
            "removeShare", isPresented: $showingRemoveConfirmation, titleVisibility: .visible
        ) {
            Button("remove", role: .destructive) {
                let ids = shareIdsToRemove
                shareIdsToRemove = []
                for id in ids {
                    do { try browseService.removePlugin(id) } catch {
                        errorMessage = error.localizedDescription
                        break
                    }
                }
            }
            Button("cancel", role: .cancel) { shareIdsToRemove = [] }
        } message: {
            if shareIdsToRemove.count == 1 {
                Text("removeShareConfirmation")
            } else {
                Text("removeSharesConfirmation")
            }
        }
        .alert(
            "failedToRemoveShare",
            isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("ok", role: .cancel) { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }
}

private func shareTypeName(for share: BrowsablePlugin) -> String {
    switch share { case is AppDirBrowsablePlugin, is FsBrowsablePlugin:
        return String(localized: "fs")
        case is SmbBrowsablePlugin: return String(localized: "smb")
        case is NfsBrowsablePlugin: return String(localized: "nfs")
        case is WebDavBrowsablePlugin: return String(localized: "webdav")
        case is OpdsBrowsablePlugin: return String(localized: "opds")
        default: return String(localized: "share")
    }
}
