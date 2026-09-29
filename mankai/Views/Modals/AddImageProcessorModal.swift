//
//  AddImageProcessorModal.swift
//  mankai
//
//  Created by Travis XU on 26/9/2026.
//

import SwiftUI

struct AddImageProcessorModal: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = ImageProcessingService.shared

    var body: some View {
        NavigationStack {
            List {
                Section("local") {
                    Button {
                        if service.add(UpscalingImageProcessor.defaultProcessor) { dismiss() }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(UpscalingImageProcessor.titleKey)
                            Text(UpscalingImageProcessor.descriptionKey).font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button {
                        if service.add(DownsampleImageProcessor.defaultProcessor) { dismiss() }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(DownsampleImageProcessor.titleKey)
                            Text(DownsampleImageProcessor.descriptionKey).font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button {
                        if service.add(MonochromeToneImageProcessor.defaultProcessor) { dismiss() }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MonochromeToneImageProcessor.titleKey)
                            Text(MonochromeToneImageProcessor.descriptionKey).font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Section("remote") {
                    NavigationLink {
                        AddRemoteImageProcessorScreen { dismiss() }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(RemoteImageProcessor.titleKey)
                            Text(RemoteImageProcessor.descriptionKey).font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("addImageProcessor").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }
            }
            .alert(
                "error",
                isPresented: Binding(
                    get: { service.errorMessage != nil },
                    set: { if !$0 { service.errorMessage = nil } })
            ) {
                Button("ok", role: .cancel) { service.errorMessage = nil }
            } message: {
                Text(service.errorMessage ?? "")
            }
        }
    }
}

private struct AddRemoteImageProcessorScreen: View {
    @ObservedObject private var service = ImageProcessingService.shared
    @State private var remoteURL = ""
    @State private var isAdding = false
    let onAdded: () -> Void

    var body: some View {
        List {
            Section("server") {
                TextField("serverUrl", text: $remoteURL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }
        .navigationTitle(RemoteImageProcessor.titleKey).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    addRemoteProcessor()
                } label: {
                    if isAdding { ProgressView() } else { Text("add") }
                }
                .disabled(isAdding || trimmedRemoteURL.isEmpty)
            }
        }
    }

    private var trimmedRemoteURL: String {
        remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addRemoteProcessor() {
        Task {
            isAdding = true
            defer { isAdding = false }
            do {
                let processor = try await RemoteImageProcessor.fromURL(trimmedRemoteURL)
                if service.add(processor) { onAdded() }
            } catch { service.errorMessage = error.localizedDescription }
        }
    }
}
