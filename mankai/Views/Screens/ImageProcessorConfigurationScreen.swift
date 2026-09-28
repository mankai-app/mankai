//
//  ImageProcessorConfigurationScreen.swift
//  mankai
//
//  Created by Travis XU on 26/9/2026.
//

import SwiftUI

struct ImageProcessorConfigurationScreen: View {
    let id: String
    @ObservedObject private var service = ImageProcessingService.shared

    private var model: ImageProcessorInstance? { service.processors.first(where: { $0.id == id }) }

    var body: some View {
        Form {
            if let model {
                if model.type == UpscalingImageProcessor.type,
                    let processor = service.processor(id: id, as: UpscalingImageProcessor.self)
                {
                    Section("imageUpscaling") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("upscaleSensitivity")
                                Spacer()
                                Text(processor.sensitivityLabel).foregroundStyle(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: {
                                        service.processor(id: id, as: UpscalingImageProcessor.self)?
                                            .threshold ?? processor.threshold
                                    },
                                    set: {
                                        service.update(
                                            id: id,
                                            processor: UpscalingImageProcessor(
                                                context: processor.context, threshold: $0))
                                    }), in: 0.5...2.5, step: 0.5)
                            Text("upscaleSensitivityDescription").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if model.type == DownsampleImageProcessor.type,
                    let processor = service.processor(id: id, as: DownsampleImageProcessor.self)
                {
                    Section("downsampleImages") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("downsampleMemorySavings")
                                Spacer()
                                Text(processor.memorySavingsLabel).foregroundStyle(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: {
                                        service.processor(
                                            id: id, as: DownsampleImageProcessor.self)?
                                            .aggressiveness ?? processor.aggressiveness
                                    },
                                    set: {
                                        service.update(
                                            id: id,
                                            processor: DownsampleImageProcessor(aggressiveness: $0))
                                    }), in: 0...1, step: 0.5)
                            Text("downsampleMemorySavingsDescription").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if model.type == RemoteImageProcessor.type,
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

                    if !processor.configs.isEmpty {
                        Section("configs") { ConfigView(configurable: processor) }
                    }
                } else {
                    Text("imageProcessorNoSettings").foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("imageProcessorRemoved", systemImage: "slider.horizontal.3")
            }
        }
        .navigationTitle("configs").navigationBarTitleDisplayMode(.inline)
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
}
