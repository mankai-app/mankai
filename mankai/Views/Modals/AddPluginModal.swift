//
//  AddPluginModal.swift
//  mankai
//
//  Created by Travis XU on 22/6/2025.
//

import SwiftUI

struct AddPluginModal: View {
    @Environment(\.dismiss) var dismiss

    enum PluginType: String, CaseIterable, Identifiable {
        case jsPlugin
        case fsPlugin
        case httpPlugin

        var id: String { rawValue }

        var localizedName: String {
            switch self { case .jsPlugin: String(localized: "js") case .fsPlugin:
                String(localized: "fs")
                case .httpPlugin: String(localized: "http")
            }
        }

        var color: Color {
            switch self { case .jsPlugin:
                Color(.sRGB, red: 0xEF / 255.0, green: 0xD8 / 255.0, blue: 0x1C / 255.0)
                case .fsPlugin: .blue
                case .httpPlugin:
                    Color(.sRGB, red: 0x01 / 255.0, green: 0x58 / 255.0, blue: 0x96 / 255.0)
            }
        }

        @ViewBuilder var icon: some View {
            switch self { case .jsPlugin:
                Text(verbatim: "JS").font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                case .fsPlugin: Image(systemName: "folder.fill")
                case .httpPlugin: Image(systemName: "globe")
            }
        }
    }

    @State private var useJson = false
    @State private var jsonInput: String = ""
    @State private var urlInput: String = ""

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
                Section("local") { pluginTypeLink(.fsPlugin) }

                Section("remote") {
                    pluginTypeLink(.jsPlugin)
                    pluginTypeLink(.httpPlugin)
                }
            }
            .navigationBarTitleDisplayMode(.inline).navigationTitle("addPlugin")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }
            }
        }
        .alert("failedToAddPlugin", isPresented: $showError) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("duplicatePluginTitle", isPresented: duplicatePluginIsPresented) {
            Button("overwrite", role: .destructive) { overwriteDuplicatePlugin() }
            Button("cancel", role: .cancel) { duplicatePlugin = nil }
        } message: {
            if let duplicatePlugin {
                Text(
                    String(
                        format: String(localized: "duplicatePluginIdMessageFormat"),
                        duplicatePlugin.id))
            }
        }
    }

    private func pluginTypeLink(_ type: PluginType) -> some View {
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

    private func configuration(for type: PluginType) -> some View {
        List {
            switch type { case .jsPlugin:
                Section("jsPluginSettings") {
                    Toggle(isOn: $useJson) { Text("useJson") }
                    if useJson {
                        TextField("json", text: $jsonInput).textInputAutocapitalization(.never)
                    } else {
                        TextField("url", text: $urlInput).keyboardType(.URL)
                            .textInputAutocapitalization(.never)
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
                        Text("fsPluginSettings")
                    } footer: {
                        Text("pluginIdSyncHint")
                    }
                case .httpPlugin:
                    Section("httpPluginSettings") {
                        TextField("url", text: $urlInput).keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                    }
            }
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

    private func canAddPlugin(_ type: PluginType) -> Bool {
        guard !isProcessing else { return false }

        switch type { case .jsPlugin: return useJson ? !jsonInput.isEmpty : !urlInput.isEmpty
            case .fsPlugin: return selectedFolder != nil
            case .httpPlugin: return !urlInput.isEmpty
        }
    }

    private func addConfiguredPlugin(_ type: PluginType) {
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
                    errorMessage = String(localized: "failedToParsePlugin")
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
                    guard let plugin = await PluginService.shared.decodeURL(urlInput, type: "http")
                    else {
                        errorMessage = String(localized: "failedToParsePlugin")
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
