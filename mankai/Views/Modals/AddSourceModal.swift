//
//  AddSourceModal.swift
//  mankai
//
//  Created by Travis XU on 22/6/2025.
//

import SwiftUI

struct AddSourceModal: View {
    @Environment(\.dismiss) var dismiss

    enum SourceType: String, CaseIterable, Identifiable {
        case jsPlugin
        case fsPlugin
        case httpPlugin
        case komgaPlugin
        case kavitaPlugin

        var id: String { rawValue }

        var localizedName: String {
            switch self { case .jsPlugin: String(localized: "js")

                case .fsPlugin: String(localized: "fs")

                case .httpPlugin: String(localized: "mankaiCompatible")

                case .komgaPlugin: String(localized: "komgaServer")

                case .kavitaPlugin: String(localized: "kavitaServer")
            }
        }

        var color: Color {
            switch self { case .jsPlugin:
                Color(.sRGB, red: 0xEF / 255.0, green: 0xD8 / 255.0, blue: 0x1C / 255.0)

                case .fsPlugin: .blue

                case .httpPlugin: .clear

                case .komgaPlugin: .clear

                case .kavitaPlugin: .clear
            }
        }

        @ViewBuilder var icon: some View {
            switch self { case .jsPlugin:
                Text(verbatim: "JS").font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)

                case .fsPlugin: Image(systemName: "folder.fill")

                case .httpPlugin:
                    Image("SakuraIconPreview").renderingMode(.original).resizable().scaledToFit()
                        .frame(width: 28, height: 28)

                case .komgaPlugin:
                    Image("KomgaIcon").renderingMode(.original).resizable().scaledToFit()
                        .frame(width: 28, height: 28)

                case .kavitaPlugin:
                    Image("KavitaIcon").renderingMode(.original).resizable().scaledToFit()
                        .frame(width: 28, height: 28)
            }
        }
    }

    @State private var useJson = false
    @State private var jsonInput: String = ""
    @State private var urlInput: String = ""

    // HttpPlugin States
    @State private var httpUsername = ""
    @State private var httpPassword = ""

    // KomgaPlugin States
    @State private var komgaName = ""
    @State private var komgaUsername = ""
    @State private var komgaPassword = ""
    @State private var komgaApiKey = ""

    // KavitaPlugin States
    @State private var kavitaName = ""
    @State private var kavitaUsername = ""
    @State private var kavitaPassword = ""
    @State private var kavitaApiKey = ""

    // FsPlugin States
    @State private var selectedFolder: URL?
    @State private var isReadOnly: Bool = false
    @State private var showFileImporter: Bool = false

    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var isProcessing: Bool = false
    @State private var duplicatePlugin: Plugin?

    var body: some View {
        NavigationStack {
            List {
                Section("localSources") { sourceTypeLink(.fsPlugin) }

                Section("remoteSources") {
                    sourceTypeLink(.jsPlugin)
                    sourceTypeLink(.httpPlugin)
                }

                Section("integrations") {
                    sourceTypeLink(.komgaPlugin)
                    sourceTypeLink(.kavitaPlugin)
                }
            }
            .navigationBarTitleDisplayMode(.inline).navigationTitle("addSource")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }
            }
        }
        .alert("failedToAddSource", isPresented: $showError) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("duplicateSourceTitle", isPresented: duplicatePluginIsPresented) {
            Button("overwrite", role: .destructive) { overwriteDuplicatePlugin() }
            Button("cancel", role: .cancel) { duplicatePlugin = nil }
        } message: {
            if let duplicatePlugin {
                Text(
                    String(
                        format: String(localized: "duplicateSourceIdMessageFormat"),
                        duplicatePlugin.id))
            }
        }
    }

    private func sourceTypeLink(_ type: SourceType) -> some View {
        NavigationLink {
            configuration(for: type)
        } label: {
            Label {
                Text(type.localizedName)
            } icon: {
                type.icon
            }
            .labelStyle(ColorfulIconLabelStyle(color: type.color))
        }
    }

    private func configuration(for type: SourceType) -> some View {
        List {
            switch type { case .jsPlugin:
                Section("jsPluginSettings") {
                    Toggle(isOn: $useJson) { Text("useJson") }
                    if useJson {
                        TextField("json", text: $jsonInput).textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        TextField("pluginLink", text: $urlInput).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }

                case .fsPlugin:
                    Section {
                        Button(action: { showFileImporter = true }) {
                            HStack {
                                Text("selectFolder")
                                Spacer()
                                if let selectedFolder {
                                    Text(selectedFolder.lastPathComponent)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("none").foregroundColor(.secondary)
                                }
                            }
                        }

                        Toggle("readOnly", isOn: $isReadOnly)
                    } header: {
                        Text("fsSourceSettings")
                    } footer: {
                        Text("sourceIdSyncHint")
                    }

                case .httpPlugin:
                    Section("mankaiCompatibleServerSettings") {
                        TextField("serverUrl", text: $urlInput).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }

                    Section("credentials") {
                        TextField("username", text: $httpUsername)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("password", text: $httpPassword)
                    }

                case .komgaPlugin:
                    Section("displayName") { TextField("default", text: $komgaName) }

                    Section {
                        TextField("serverUrl", text: $urlInput).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: {
                        Text("komgaServerSettings")
                    } footer: {
                        Text("komgaServerIdSyncHint")
                    }

                    Section {
                        TextField("username", text: $komgaUsername)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("password", text: $komgaPassword)
                        SecureField("apiKey", text: $komgaApiKey)
                    } header: {
                        Text("credentials")
                    } footer: {
                        Text("komgaAuthenticationHint")
                    }

                case .kavitaPlugin:
                    Section("displayName") { TextField("default", text: $kavitaName) }

                    Section {
                        TextField("serverUrl", text: $urlInput).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: {
                        Text("kavitaServerSettings")
                    } footer: {
                        Text("kavitaServerIdSyncHint")
                    }

                    Section {
                        TextField("username", text: $kavitaUsername)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("password", text: $kavitaPassword)
                        SecureField("apiKey", text: $kavitaApiKey)
                    } header: {
                        Text("credentials")
                    } footer: {
                        Text("kavitaAuthenticationHint")
                    }
            }
        }
        .onChange(of: urlInput, initial: true) { _, url in
            autofillConfiguration(from: url, for: type)
        }
        .disabled(isProcessing).navigationTitle(type.localizedName)
        .navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden(isProcessing)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    addConfiguredPlugin(type)
                } label: {
                    if isProcessing { ProgressView() } else { Text("add") }
                }
                .disabled(!canAddPlugin(type))
            }
        }
        .fileImporter(
            isPresented: $showFileImporter, allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result { case .success(let urls): selectedFolder = urls.first

                case .failure(let error):
                    errorMessage = error.localizedDescription
                    showError = true
            }
        }
    }

    private func autofillConfiguration(from url: String, for type: SourceType) {
        guard let configuration = PluginURLConfiguration(url) else { return }

        let values = configuration.configValues

        switch type { case .httpPlugin:
            if let username = values["username"] { httpUsername = username }
            if let password = values["password"] { httpPassword = password }

            case .komgaPlugin:
                if let name = values["name"] { komgaName = name }
                if let username = values["username"] { komgaUsername = username }
                if let password = values["password"] { komgaPassword = password }
                if let apiKey = values["apiKey"] { komgaApiKey = apiKey }

            case .kavitaPlugin:
                if let name = values["name"] { kavitaName = name }
                if let username = values["username"] { kavitaUsername = username }
                if let password = values["password"] { kavitaPassword = password }
                if let apiKey = values["apiKey"] { kavitaApiKey = apiKey }

            case .jsPlugin, .fsPlugin: break
        }
    }

    private func configuredPluginURL(for type: SourceType) -> String? {
        guard let configuration = PluginURLConfiguration(urlInput) else { return nil }

        let values: [String: String]

        switch type { case .httpPlugin:
            values = ["username": httpUsername, "password": httpPassword]

            case .komgaPlugin:
                values = [
                    "name": komgaName, "username": komgaUsername, "password": komgaPassword,
                    "apiKey": komgaApiKey
                ]

            case .kavitaPlugin:
                values = [
                    "name": kavitaName, "username": kavitaUsername, "password": kavitaPassword,
                    "apiKey": kavitaApiKey
                ]

            case .jsPlugin, .fsPlugin: return nil
        }

        return configuration.url(overriding: values)?.absoluteString
    }

    private func canAddPlugin(_ type: SourceType) -> Bool {
        guard !isProcessing else { return false }

        switch type { case .jsPlugin: return useJson ? !jsonInput.isEmpty : !urlInput.isEmpty

            case .fsPlugin: return selectedFolder != nil

            case .httpPlugin, .komgaPlugin, .kavitaPlugin:
                return PluginURLConfiguration(urlInput) != nil
        }
    }

    private func addConfiguredPlugin(_ type: SourceType) {
        isProcessing = true
        Task {
            defer { isProcessing = false }

            switch type { case .jsPlugin:
                let plugin: JsPlugin?

                if useJson {
                    plugin = jsonInput.data(using: .utf8)
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        .flatMap { JsPlugin.fromJson($0) }
                } else {
                    plugin = await PluginService.shared.decodeURL(urlInput, type: "js") as? JsPlugin
                }

                guard let plugin = plugin else {
                    errorMessage = String(localized: "failedToParseSource")
                    showError = true
                    return
                }

                addPlugin(plugin)

                case .fsPlugin:
                    guard let selectedFolder = selectedFolder else {
                        errorMessage = String(localized: "noFolderSelected")
                        showError = true
                        return
                    }

                    // Check if the folder is accessible
                    guard selectedFolder.startAccessingSecurityScopedResource() else {
                        errorMessage = String(localized: "failedToAccessFolder")
                        showError = true
                        return
                    }
                    defer { selectedFolder.stopAccessingSecurityScopedResource() }

                    let plugin: ReadFsPlugin
                    do {
                        if isReadOnly {
                            plugin = try ReadFsPlugin(url: selectedFolder)
                        } else {
                            plugin = try ReadWriteFsPlugin(url: selectedFolder)
                        }

                        addPlugin(plugin)
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }

                case .httpPlugin:
                    guard let url = configuredPluginURL(for: type),
                        let plugin = await PluginService.shared.decodeURL(url, type: "http")
                    else {
                        errorMessage = String(localized: "failedToParseSource")
                        showError = true
                        return
                    }

                    addPlugin(plugin)

                case .komgaPlugin:
                    guard let url = configuredPluginURL(for: type),
                        let plugin = await PluginService.shared.decodeURL(url, type: "komga")
                            as? KomgaPlugin
                    else {
                        errorMessage = String(localized: "failedToParseSource")
                        showError = true
                        return
                    }

                    addPlugin(plugin)

                case .kavitaPlugin:
                    guard let url = configuredPluginURL(for: type),
                        let plugin = await PluginService.shared.decodeURL(url, type: "kavita")
                            as? KavitaPlugin
                    else {
                        errorMessage = String(localized: "failedToParseSource")
                        showError = true
                        return
                    }

                    addPlugin(plugin)
            }
        }
    }

    private var duplicatePluginIsPresented: Binding<Bool> {
        Binding(get: { duplicatePlugin != nil }, set: { if !$0 { duplicatePlugin = nil } })
    }

    private func addPlugin(_ plugin: Plugin) {
        do {
            try PluginService.shared.addPlugin(plugin)
            dismiss()
        } catch let error where MankaiErrorCode.pluginDuplicateId.matches(error) {
            duplicatePlugin = plugin
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func overwriteDuplicatePlugin() {
        guard let duplicatePlugin else { return }
        self.duplicatePlugin = nil

        do {
            try PluginService.shared.addPlugin(duplicatePlugin, conflictResolution: .overwrite)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
