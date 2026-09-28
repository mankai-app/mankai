//
//  ImageProcessorSettingsScreen.swift
//  mankai
//
//  Created by Travis XU on 26/9/2026.
//

import SwiftUI

struct ImageProcessorSettingsScreen: View {
    @Environment(\.editMode) private var editMode
    @ObservedObject private var service = ImageProcessingService.shared
    @State private var showingAdd = false
    @State private var showingDeleteConfirmation = false
    @State private var processorIdsToRemove: [String] = []

    var body: some View {
        List {
            SettingsHeaderView(
                image: Image(systemName: "photo.on.rectangle.angled.fill"), color: .purple,
                title: String(localized: "imageProcessing"),
                description: String(localized: "imageProcessingDescription"))

            if service.processors.isEmpty {
                ContentUnavailableView(
                    "imageProcessorEmptyTitle", systemImage: "photo.on.rectangle.angled",
                    description: Text("imageProcessorEmptyDescription"))
            } else {
                Section {
                    ForEach(service.processors, id: \.id) { model in
                        HStack {
                            if editMode?.wrappedValue.isEditing == true {
                                Text(model.title)
                            } else {
                                NavigationLink {
                                    ImageProcessorConfigurationScreen(id: model.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.title)
                                        Text(model.description).font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                Toggle(
                                    isOn: Binding(
                                        get: {
                                            service.processors.first(where: { $0.id == model.id })?
                                                .isEnabled ?? false
                                        }, set: { service.setEnabled($0, for: model.id) })
                                ) { Text(model.title) }
                                .labelsHidden()
                            }
                        }
                    }
                    .onMove { source, destination in
                        var ids = service.processors.map(\.id)
                        ids.move(fromOffsets: source, toOffset: destination)
                        service.setOrder(ids)
                    }
                    .onDelete { offsets in
                        processorIdsToRemove = offsets.map { service.processors[$0].id }
                        showingDeleteConfirmation = true
                    }
                } header: {
                    Text("imageProcessor")
                } footer: {
                    Text("imageProcessorOrderHint")
                }
            }
        }
        .navigationTitle("imageProcessing").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !service.processors.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    ToolbarIcon(systemName: "plus", legacySystemName: "plus.circle")
                }
            }
        }
        .sheet(isPresented: $showingAdd) { AddImageProcessorModal() }
        .confirmationDialog(
            "remove", isPresented: $showingDeleteConfirmation, titleVisibility: .visible
        ) {
            Button("remove", role: .destructive) {
                service.remove(ids: processorIdsToRemove)
                processorIdsToRemove = []
            }
            Button("cancel", role: .cancel) { processorIdsToRemove = [] }
        } message: {
            Text("removeImageProcessorsConfirmation")
        }
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
