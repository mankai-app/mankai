//
//  SyncEngine.swift
//  mankai
//
//  Created by Travis XU on 21/7/2025.
//

import Foundation

@MainActor class SyncEngine: Identifiable, ObservableObject, Hashable {
    init() {}

    static func == (lhs: SyncEngine, rhs: SyncEngine) -> Bool { return lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The unique identifier of the sync engine.
    /// - Returns: A unique string identifier.
    var id: String { fatalError("Not Implemented") }

    /// The display name of the sync engine.
    /// - Returns: A user-friendly name.
    var name: String { fatalError("Not Implemented") }

    /// Indicates if the sync engine is currently active.
    /// - Returns: `true` if active, `false` otherwise.
    var active: Bool { fatalError("Not Implemented") }

    /// Performs a synchronization operation.
    /// - Throws: An error if the synchronization fails.
    func sync() async throws { fatalError("Not Implemented") }

    /// Called when the sync engine is selected by the user.
    /// - Throws: An error if the activation process fails.
    func onSelected() async throws { fatalError("Not Implemented") }

}
