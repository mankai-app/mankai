//
//  AddPluginsModal.swift
//  mankai
//
//  Created by Travis XU on 12/8/2026.
//

import SwiftUI

struct PluginImportSource: Identifiable {
    enum Kind: String {
        case js
        case http
    }

    let id = UUID()
    let kind: Kind
    let url: URL
}

struct PluginImportRequest: Identifiable {
    let id = UUID()
    let sources: [PluginImportSource]
}

struct AddPluginsModal: View {
    private struct Candidate: Identifiable {
        let source: PluginImportSource
        var plugin: Plugin?
        var isLoading = true

        var id: UUID { source.id }
    }

    @Environment(\.dismiss) private var dismiss

    let sources: [PluginImportSource]

    @State private var candidates: [Candidate] = []
    @State private var selectedSourceIds: Set<UUID> = []
    @State private var isLoading = true
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var duplicatePluginIDs: [String] = []

    var body: some View {
        NavigationStack {
            List(candidates) { candidate in
                if candidate.isLoading {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                } else if let plugin = candidate.plugin {
                    Button {
                        if selectedSourceIds.contains(candidate.id) {
                            selectedSourceIds.remove(candidate.id)
                        } else {
                            selectedSourceIds.insert(candidate.id)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(
                                systemName: selectedSourceIds.contains(candidate.id)
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            .font(.title3)
                            .foregroundStyle(
                                selectedSourceIds.contains(candidate.id)
                                    ? Color.accentColor : .secondary)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(plugin.name ?? plugin.id).foregroundStyle(.primary)

                                    Text(LocalizedStringKey(candidate.source.kind.rawValue))
                                        .smallTagStyle()

                                    if let version = plugin.version {
                                        Text(verbatim: "v\(version)").smallTagStyle()
                                    }
                                }

                                if let description = plugin.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill").font(.title3)
                            .foregroundStyle(.red)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("failedToParsePlugin").foregroundStyle(.red)

                            Text(candidate.source.url.absoluteString).font(.caption2)
                                .foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .navigationTitle("addPlugins").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }

                ToolbarItem(placement: .confirmationAction) {
                    Button("add") { addSelectedPlugins() }
                        .disabled(isLoading || isAdding || selectedSourceIds.isEmpty)
                }
            }
            .task { await loadCandidates() }
            .alert(
                "failedToAddPlugin",
                isPresented: Binding(
                    get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("ok", role: .cancel) {}
            } message: {
                if let errorMessage { Text(errorMessage) }
            }
            .alert("duplicatePluginTitle", isPresented: duplicatePluginsArePresented) {
                Button("overwrite", role: .destructive) {
                    duplicatePluginIDs = []
                    performAddSelectedPlugins(overwriteDuplicates: true)
                }
                Button("cancel", role: .cancel) { duplicatePluginIDs = [] }
            } message: {
                Text(
                    String(
                        format: String(localized: "duplicatePluginIdMessageFormat"),
                        duplicatePluginIDs.joined(separator: ", ")))
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.hidden)
    }

    private func loadCandidates() async {
        candidates = sources.map { Candidate(source: $0) }

        await withTaskGroup(of: (Int, Plugin?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    let plugin = await PluginService.shared.decodeURL(
                        source.url.absoluteString, type: source.kind.rawValue)

                    return (index, plugin)
                }
            }

            for await (index, plugin) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }

                candidates[index].plugin = plugin
                candidates[index].isLoading = false

                if plugin != nil { selectedSourceIds.insert(candidates[index].id) }
            }
        }

        guard !Task.isCancelled else { return }
        isLoading = false
    }

    private func addSelectedPlugins() {
        var seenPluginIDs: Set<String> = []
        var duplicateIDs: Set<String> = []

        for candidate in candidates where selectedSourceIds.contains(candidate.id) {
            guard let plugin = candidate.plugin else { continue }

            if PluginService.shared.getPlugin(plugin.id) != nil
                || !seenPluginIDs.insert(plugin.id).inserted
            {
                duplicateIDs.insert(plugin.id)
            }
        }

        if !duplicateIDs.isEmpty {
            duplicatePluginIDs = duplicateIDs.sorted()
            return
        }

        performAddSelectedPlugins(overwriteDuplicates: false)
    }

    private var duplicatePluginsArePresented: Binding<Bool> {
        Binding(get: { !duplicatePluginIDs.isEmpty }, set: { if !$0 { duplicatePluginIDs = [] } })
    }

    private func performAddSelectedPlugins(overwriteDuplicates: Bool) {
        isAdding = true
        defer { isAdding = false }

        var failures: [(id: UUID, message: String)] = []

        for candidate in candidates where selectedSourceIds.contains(candidate.id) {
            guard let plugin = candidate.plugin else { continue }

            do {
                try PluginService.shared.addPlugin(
                    plugin, conflictResolution: overwriteDuplicates ? .overwrite : .reject)
            } catch {
                let name = plugin.name ?? plugin.id
                failures.append((candidate.id, "\(name): \(error.localizedDescription)"))
            }
        }

        if failures.isEmpty {
            dismiss()
        } else {
            selectedSourceIds = Set(failures.map(\.id))
            errorMessage = failures.map(\.message).joined(separator: "\n")
        }
    }
}
