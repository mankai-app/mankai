//
//  HomeFilterModal.swift
//  mankai
//
//  Created by Travis XU on 16/2/2026.
//

import SwiftUI

struct HomeFilterModal: View {
    @Binding var isPresented: Bool
    @Binding var showPlugins: [String]
    let availablePlugins: [Plugin]
    let availableShares: [BrowsablePlugin]
    let onReset: () -> Void
    let onApply: () -> Void

    @State private var tempShowPlugins: [String]

    init(
        isPresented: Binding<Bool>, showPlugins: Binding<[String]>, availablePlugins: [Plugin],
        availableShares: [BrowsablePlugin], onReset: @escaping () -> Void,
        onApply: @escaping () -> Void
    ) {
        _isPresented = isPresented
        _showPlugins = showPlugins
        self.availablePlugins = availablePlugins
        self.availableShares = availableShares
        self.onReset = onReset
        self.onApply = onApply
        _tempShowPlugins = State(initialValue: showPlugins.wrappedValue)
    }

    var body: some View {
        NavigationView {
            List {
                if !availablePlugins.isEmpty {
                    Section("plugins") {
                        ForEach(availablePlugins, id: \.id) { plugin in filterButton(for: plugin) }
                    }
                }

                if !availableShares.isEmpty {
                    Section("shares") {
                        ForEach(availableShares, id: \.id) { share in filterButton(for: share) }
                    }
                }

                Section {
                    Button(
                        "reset", role: .destructive,
                        action: {
                            onReset()
                            isPresented = false
                        })
                }
            }
            .navigationTitle("filters").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { isPresented = false }) { Text("cancel") }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(action: {
                        showPlugins = tempShowPlugins
                        onApply()
                        isPresented = false
                    }) { Text("done") }
                }
            }
        }
        .presentationDetents([.medium]).onAppear { tempShowPlugins = showPlugins }
    }

    private func filterButton(for plugin: Plugin) -> some View {
        Button {
            if tempShowPlugins.contains(plugin.id) {
                tempShowPlugins.removeAll { $0 == plugin.id }
            } else {
                tempShowPlugins.append(plugin.id)
            }
        } label: {
            HStack {
                Text(plugin.name ?? plugin.id).foregroundColor(.primary)
                Spacer()
                if tempShowPlugins.contains(plugin.id) { Image(systemName: "checkmark") }
            }
        }
    }
}
