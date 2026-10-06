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
    }

    @State private var selectedPluginType: PluginType = .jsPlugin
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
        NavigationView {
            List {
                Section {
                    Picker("pluginType", selection: $selectedPluginType) {
                        ForEach(PluginType.allCases) { type in
                            switch type { case .jsPlugin: Text("js").tag(type) case .fsPlugin:
                                Text("fs").tag(type)
                                case .httpPlugin: Text("http").tag(type)
                            }
                        }
                    }
                }

                if selectedPluginType == .jsPlugin {
                    Section {
                        Toggle(isOn: $useJson) { Text("useJson") }
                        if useJson {
                            TextField("json", text: $jsonInput).textInputAutocapitalization(.never)
                        } else {
                            TextField("url", text: $urlInput).keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                        }
                    } header: {
                        Text("jsPluginSettings")
                    }
                } else if selectedPluginType == .fsPlugin {
                    Section {
                        Button(action: { showFileImporter = true }) {
                            HStack {
                                Text("selectFolder")
                                Spacer()
                                if let selectedFolder = selectedFolder {
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
                } else if selectedPluginType == .httpPlugin {
                    Section {
                        TextField("url", text: $urlInput).keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                    } header: {
                        Text("httpPluginSettings")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline).navigationTitle("addPlugin")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) { Text("cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: {
                        Task {
                            isProcessing = true
                            defer { isProcessing = false }

                            switch selectedPluginType { case .jsPlugin:
                                let plugin: JsPlugin?

                                if useJson {
                                    plugin = jsonInput.data(using: .utf8)
                                        .flatMap {
                                            try? JSONSerialization.jsonObject(with: $0)
                                                as? [String: Any]
                                        }
                                        .flatMap { JsPlugin.fromJson($0) }
                                } else {
                                    plugin =
                                        await PluginService.shared.decodeURL("js:\(urlInput)")
                                        as? JsPlugin
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
                                    guard selectedFolder.startAccessingSecurityScopedResource()
                                    else {
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
                                    guard
                                        let plugin = await PluginService.shared.decodeURL(
                                            "http:\(urlInput)")
                                    else {
                                        errorMessage = String(localized: "failedToParsePlugin")
                                        showError = true
                                        return
                                    }

                                    addPlugin(plugin)
                            }
                        }
                    }) { if isProcessing { ProgressView() } else { Text("add") } }
                    .disabled(
                        isProcessing
                            || (selectedPluginType == .jsPlugin
                                && (useJson ? jsonInput.isEmpty : urlInput.isEmpty))
                            || (selectedPluginType == .fsPlugin && selectedFolder == nil)
                            || (selectedPluginType == .httpPlugin && urlInput.isEmpty))
                }
            }
            .fileImporter(
                isPresented: $showFileImporter, allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result { case .success(let urls):
                    if let url = urls.first { selectedFolder = url }
                    case .failure(let error):
                        errorMessage = error.localizedDescription
                        showError = true
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
