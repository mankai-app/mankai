//
//  ImageProcessorConfigurationScreen.swift
//  mankai
//
//  Created by Travis XU on 26/9/2026.
//

import SwiftUI

struct ImageProcessorConfigurationScreen: View {
    @Environment(\.dismiss) private var dismiss
    let id: String
    @ObservedObject private var service = ImageProcessingService.shared
    @State private var showResetConfirmation = false
    @State private var showRemoveConfirmation = false

    private var model: ImageProcessorInstance? { service.processors.first(where: { $0.id == id }) }

    var body: some View {
        Form {
            if let model {
                if model.type == RemoteImageProcessor.type,
                    let processor = service.processor(id: id, as: RemoteImageProcessor.self)
                {
                    Section("info") {
                        LabeledContent("id") { Text(processor.remoteID) }
                        LabeledContent("server") {
                            Text(processor.serverURL).lineLimit(1).truncationMode(.middle)
                        }
                        if let version = processor.version {
                            LabeledContent("version") { Text(version) }
                        }
                        if !processor.authors.isEmpty {
                            LabeledContent("authors") {
                                Text(processor.authors.joined(separator: ", "))
                            }
                        }
                        if let repository = processor.repository {
                            LabeledContent("repository") { Text(repository) }
                        }
                    }
                }

                if let configurable = model.processor as? any Configurable & ObservableObject,
                    !configurable.configs.isEmpty
                {
                    Section("configs") { configView(for: configurable) }
                }

                Section("actions") {
                    if let configurable = model.processor as? any Configurable,
                        !configurable.configs.isEmpty
                    {
                        Button("resetConfigs", role: .destructive) { showResetConfirmation = true }
                            .confirmationDialog(
                                "resetConfigs", isPresented: $showResetConfirmation,
                                titleVisibility: .visible
                            ) {
                                Button("reset", role: .destructive) {
                                    do { try configurable.resetConfigs() } catch {
                                        service.errorMessage = error.localizedDescription
                                    }
                                }
                                Button("cancel", role: .cancel) {}
                            } message: {
                                Text("resetConfigsConfirmation")
                            }
                    }

                    Button("remove", role: .destructive) { showRemoveConfirmation = true }
                        .confirmationDialog(
                            "remove", isPresented: $showRemoveConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("remove", role: .destructive) {
                                service.remove(ids: [id])
                                if !service.processors.contains(where: { $0.id == id }) {
                                    dismiss()
                                }
                            }
                            Button("cancel", role: .cancel) {}
                        } message: {
                            Text("removeImageProcessorsConfirmation")
                        }
                }
            } else {
                ContentUnavailableView("imageProcessorRemoved", systemImage: "slider.horizontal.3")
            }
        }
        .navigationTitle(model?.title ?? "").navigationBarTitleDisplayMode(.inline)
        .alert(
            "error",
            isPresented: Binding(
                get: { service.errorMessage != nil }, set: { if !$0 { service.errorMessage = nil } }
            )
        ) {
            Button("ok", role: .cancel) { service.errorMessage = nil }
        } message: {
            Text(service.errorMessage ?? "")
        }
    }

    private func configView<ConfigurableObject: Configurable & ObservableObject>(
        for configurable: ConfigurableObject
    ) -> AnyView { AnyView(ConfigView(configurable: configurable)) }
}
