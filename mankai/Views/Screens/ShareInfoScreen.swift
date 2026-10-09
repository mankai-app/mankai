//
//  ShareInfoScreen.swift
//  mankai
//
//  Created by Travis XU on 20/8/2026.
//

import SwiftUI

struct ShareInfoScreen: View {
    @State private var share: BrowsablePlugin

    @ObservedObject private var browseService = BrowseService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var username: String
    @State private var password: String

    @State private var errorTitle: LocalizedStringKey = "failedToSaveShare"
    @State private var errorMessage: String?
    @State private var hasSettingsChanges = false
    @State private var showingRemoveConfirmation = false

    init(share: BrowsablePlugin) {
        _share = State(initialValue: share)

        _name = State(initialValue: share.displayName ?? "")

        let credentials: (username: String?, password: String?)
        switch share { case let smbShare as SmbBrowsablePlugin:
            credentials = (
                username: smbShare.configuration.username, password: smbShare.configuration.password
            )
            case let webDavShare as WebDavBrowsablePlugin:
                credentials = (
                    username: webDavShare.configuration.username,
                    password: webDavShare.configuration.password
                )
            case let opdsShare as OpdsBrowsablePlugin:
                credentials = (
                    username: opdsShare.configuration.username,
                    password: opdsShare.configuration.password
                )
            default: credentials = (username: nil, password: nil)
        }

        _username = State(initialValue: credentials.username ?? "")
        _password = State(initialValue: credentials.password ?? "")
    }

    private var isEditable: Bool { !(share is AppDirBrowsablePlugin) }

    private var shareSyncDisabledReason: LocalizedStringKey {
        if share is AppDirBrowsablePlugin { return "syncShareBuiltInDescription" }
        if share is FsBrowsablePlugin { return "syncShareFilesystemDescription" }
        return "syncShareUnsupportedDescription"
    }

    private var mangaSyncDisabledReason: LocalizedStringKey {
        if share is AppDirBrowsablePlugin { return "syncShareMangaBuiltInDescription" }
        return "syncShareMangaLocalIDDescription"
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var shareTypeName: LocalizedStringKey {
        switch share { case is FsBrowsablePlugin: "fs" case is SmbBrowsablePlugin: "smb"
            case is NfsBrowsablePlugin: "nfs"
            case is WebDavBrowsablePlugin: "webdav"
            case is OpdsBrowsablePlugin: "opds"
            default: "share"
        }
    }

    var body: some View {
        Form {
            Section("info") {
                LabeledContent("id") { Text(share.id).lineLimit(1).truncationMode(.middle) }

                LabeledContent("shareType") { Text(shareTypeName) }
            }

            Section("sync") {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("syncShareAcrossDevices") {
                        HStack(spacing: 8) {
                            Circle().fill(share.supports(.urlEncoding) ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(share.supports(.urlEncoding) ? "syncEnabled" : "syncDisabled")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !share.supports(.urlEncoding) {
                        Text(shareSyncDisabledReason).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("syncShareDescription").font(.caption).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("syncMangaAcrossDevices") {
                        HStack(spacing: 8) {
                            Circle().fill(share.supports(.sync) ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(share.supports(.sync) ? "syncEnabled" : "syncDisabled")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !share.supports(.sync) {
                        Text(mangaSyncDisabledReason).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("syncShareMangaDescription").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if isEditable {
                Section {
                    TextField("default", text: $name)
                        .onChange(of: name, initial: false) { updateSettings() }
                } header: {
                    Text("displayName")
                }
            }

            switch share { case let filesystemShare as FsBrowsablePlugin:
                Section("filesystemSettings") {
                    LabeledContent("folder") {
                        Text(filesystemShare.url.path(percentEncoded: false)).lineLimit(1)
                    }
                }
                case let smbShare as SmbBrowsablePlugin:
                    Section("smbSettings") {
                        LabeledContent("server") { Text(smbShare.host) }

                        LabeledContent("port") { Text(String(smbShare.port)) }

                        LabeledContent("share") { Text(smbShare.share) }

                        credentialFields
                    }
                case let nfsShare as NfsBrowsablePlugin:
                    Section("nfsSettings") {
                        LabeledContent("server") { Text(nfsShare.host) }

                        LabeledContent("export") { Text(nfsShare.export).lineLimit(1) }
                    }
                case let webDavShare as WebDavBrowsablePlugin:
                    Section("webdavSettings") {
                        LabeledContent("serverUrl") {
                            Text(webDavShare.baseURL.absoluteString).lineLimit(1)
                        }

                        credentialFields
                    }
                case let opdsShare as OpdsBrowsablePlugin:
                    Section("opdsSettings") {
                        LabeledContent("catalogUrl") {
                            Text(opdsShare.configuration.catalogURL.absoluteString).lineLimit(1)
                        }

                        credentialFields
                    }
                default: EmptyView()
            }

            if isEditable {
                Section("actions") {
                    Button("removeShare", role: .destructive) { showingRemoveConfirmation = true }
                }
                .confirmationDialog(
                    "removeShare", isPresented: $showingRemoveConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("remove", role: .destructive) { removeShare() }
                    Button("cancel", role: .cancel) {}
                } message: {
                    Text("removeShareConfirmation")
                }
            }
        }
        .navigationTitle(name.isEmpty ? (share.name ?? share.id) : name)
        .navigationBarTitleDisplayMode(.inline).onDisappear { saveSettings() }
        .alert(errorTitle, isPresented: errorIsPresented) {
            Button("ok", role: .cancel) { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }

    @ViewBuilder private var credentialFields: some View {
        TextField("username", text: $username).textInputAutocapitalization(.never)
            .autocorrectionDisabled().textContentType(.username)
            .onChange(of: username, initial: false) { updateSettings() }

        SecureField("password", text: $password).textContentType(.password)
            .onChange(of: password, initial: false) { updateSettings() }
    }

    private func updateSettings() {
        share.displayName = Optional(name).trimmed

        let trimmedUsername = Optional(username).trimmed
        let trimmedPassword = Optional(password).trimmed

        switch share { case let smbShare as SmbBrowsablePlugin:
            var configuration = smbShare.configuration
            configuration.username = trimmedUsername
            configuration.password = trimmedPassword
            smbShare.configuration = configuration
            case let webDavShare as WebDavBrowsablePlugin:
                var configuration = webDavShare.configuration
                configuration.username = trimmedUsername
                configuration.password = trimmedPassword
                webDavShare.configuration = configuration
            case let opdsShare as OpdsBrowsablePlugin:
                var configuration = opdsShare.configuration
                configuration.username = trimmedUsername
                configuration.password = trimmedPassword
                opdsShare.configuration = configuration
            default: break
        }

        hasSettingsChanges = true
    }

    private func saveSettings() {
        guard isEditable, hasSettingsChanges, browseService.getPlugin(share.id) === share else {
            return
        }

        do {
            try browseService.savePlugin(share)
            hasSettingsChanges = false
        } catch {
            Logger.browseService.error("Failed to save share settings: \(share.id)", error: error)
            presentError(error)
        }
    }

    private func removeShare() {
        do {
            try browseService.removePlugin(share.id)
            dismiss()
        } catch { presentError(error, title: "failedToRemoveShare") }
    }

    private func presentError(_ error: Error, title: LocalizedStringKey = "failedToSaveShare") {
        errorTitle = title
        errorMessage = error.localizedDescription
    }
}
