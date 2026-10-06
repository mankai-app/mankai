//
//  FolderInfoScreen.swift
//  mankai
//
//  Created by Travis XU on 20/8/2026.
//

import SwiftUI

struct FolderInfoScreen: View {
    @State private var plugin: BrowsablePlugin

    @ObservedObject private var browseService = BrowseService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var username: String
    @State private var password: String

    @State private var errorTitle: LocalizedStringKey = "failedToSaveFolder"
    @State private var errorMessage: String?
    @State private var showingRemoveConfirmation = false

    init(plugin: BrowsablePlugin) {
        _plugin = State(initialValue: plugin)

        _name = State(initialValue: plugin.displayName ?? "")

        let credentials: (username: String?, password: String?)
        switch plugin { case let smbPlugin as SmbBrowsablePlugin:
            credentials = (
                username: smbPlugin.configuration.username,
                password: smbPlugin.configuration.password
            )
            case let webDavPlugin as WebDavBrowsablePlugin:
                credentials = (
                    username: webDavPlugin.configuration.username,
                    password: webDavPlugin.configuration.password
                )
            case let opdsPlugin as OpdsBrowsablePlugin:
                credentials = (
                    username: opdsPlugin.configuration.username,
                    password: opdsPlugin.configuration.password
                )
            default: credentials = (username: nil, password: nil)
        }

        _username = State(initialValue: credentials.username ?? "")
        _password = State(initialValue: credentials.password ?? "")
    }

    private var isEditable: Bool { !(plugin is AppDirBrowsablePlugin) }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var folderTypeName: LocalizedStringKey {
        switch plugin { case is FsBrowsablePlugin: "fs" case is SmbBrowsablePlugin: "smb"
            case is NfsBrowsablePlugin: "nfs"
            case is WebDavBrowsablePlugin: "webdav"
            case is OpdsBrowsablePlugin: "opds"
            default: "folder"
        }
    }

    var body: some View {
        Form {
            Section("info") {
                LabeledContent("id") { Text(plugin.id).lineLimit(1).truncationMode(.middle) }

                LabeledContent("folderType") { Text(folderTypeName) }

                LabeledContent("syncAcrossDevices") {
                    HStack(spacing: 8) {
                        Circle().fill(plugin.supports(.sync) ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(plugin.supports(.sync) ? "syncEnabled" : "syncDisabled")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if isEditable {
                Section {
                    TextField("default", text: $name)
                        .onChange(of: name, initial: false) { saveSettings() }
                } header: {
                    Text("displayName")
                }
            }

            switch plugin { case let filesystemPlugin as FsBrowsablePlugin:
                Section("filesystemSettings") {
                    LabeledContent("folder") {
                        Text(filesystemPlugin.url.path(percentEncoded: false)).lineLimit(1)
                    }
                }
                case let smbPlugin as SmbBrowsablePlugin:
                    Section("smbSettings") {
                        LabeledContent("server") { Text(smbPlugin.host) }

                        LabeledContent("port") { Text(String(smbPlugin.port)) }

                        LabeledContent("share") { Text(smbPlugin.share) }

                        credentialFields
                    }
                case let nfsPlugin as NfsBrowsablePlugin:
                    Section("nfsSettings") {
                        LabeledContent("server") { Text(nfsPlugin.host) }

                        LabeledContent("export") { Text(nfsPlugin.export).lineLimit(1) }
                    }
                case let webDavPlugin as WebDavBrowsablePlugin:
                    Section("webdavSettings") {
                        LabeledContent("serverUrl") {
                            Text(webDavPlugin.baseURL.absoluteString).lineLimit(1)
                        }

                        credentialFields
                    }
                case let opdsPlugin as OpdsBrowsablePlugin:
                    Section("opdsSettings") {
                        LabeledContent("catalogUrl") {
                            Text(opdsPlugin.configuration.catalogURL.absoluteString).lineLimit(1)
                        }

                        credentialFields
                    }
                default: EmptyView()
            }

            if isEditable {
                Section("actions") {
                    Button("removeFolder", role: .destructive) { showingRemoveConfirmation = true }
                }
                .confirmationDialog(
                    "removeFolder", isPresented: $showingRemoveConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("remove", role: .destructive) { removeFolder() }
                    Button("cancel", role: .cancel) {}
                } message: {
                    Text("removeFolderConfirmation")
                }
            }
        }
        .navigationTitle(name.isEmpty ? (plugin.name ?? plugin.id) : name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { browseService.objectWillChange.send() }
        .alert(errorTitle, isPresented: errorIsPresented) {
            Button("ok", role: .cancel) { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }

    @ViewBuilder private var credentialFields: some View {
        TextField("username", text: $username).textInputAutocapitalization(.never)
            .autocorrectionDisabled().textContentType(.username)
            .onChange(of: username, initial: false) { saveSettings() }

        SecureField("password", text: $password).textContentType(.password)
            .onChange(of: password, initial: false) { saveSettings() }
    }

    private func saveSettings() {
        do {
            plugin.displayName = Optional(name).trimmed

            let trimmedUsername = Optional(username).trimmed
            let trimmedPassword = Optional(password).trimmed

            switch plugin { case let smbPlugin as SmbBrowsablePlugin:
                var configuration = smbPlugin.configuration
                configuration.username = trimmedUsername
                configuration.password = trimmedPassword
                smbPlugin.configuration = configuration
                case let webDavPlugin as WebDavBrowsablePlugin:
                    var configuration = webDavPlugin.configuration
                    configuration.username = trimmedUsername
                    configuration.password = trimmedPassword
                    webDavPlugin.configuration = configuration
                case let opdsPlugin as OpdsBrowsablePlugin:
                    var configuration = opdsPlugin.configuration
                    configuration.username = trimmedUsername
                    configuration.password = trimmedPassword
                    opdsPlugin.configuration = configuration
                default: break
            }

            try plugin.savePlugin()
        } catch { presentError(error) }
    }

    private func removeFolder() {
        do {
            try browseService.removePlugin(plugin.id)
            dismiss()
        } catch { presentError(error, title: "failedToRemovePlugin") }
    }

    private func presentError(_ error: Error, title: LocalizedStringKey = "failedToSaveFolder") {
        errorTitle = title
        errorMessage = error.localizedDescription
    }
}
