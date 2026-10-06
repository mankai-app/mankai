//
//  HttpEngine.swift
//  mankai
//
//  Created by Travis XU on 4/8/2025.
//

import Foundation

final class HttpEngine: MutationSyncEngine {
    static let shared = HttpEngine()

    private let authManager: AuthManager

    override private init() {
        Logger.httpEngine.debug("Initializing HttpEngine")
        authManager = AuthManager(id: "HttpEngine")
        super.init()
        authManager.postSave = { [weak self] in self?.objectWillChange.send() }
        authManager.postLogin = { Task { try? await SyncService.shared.onEngineChange() } }
    }

    override var id: String { "HttpEngine" }
    override var name: String { String(localized: "httpEngine") }
    override var active: Bool { authManager.loggedIn }
    var username: String? { authManager.username }

    var serverUrl: String? {
        get { authManager.serverUrl }
        set {
            let url = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard url != authManager.serverUrl else { return }
            Logger.httpEngine.debug("HTTP sync server changed, resetting authentication")
            logout()
            authManager.serverUrl = url
        }
    }

    private var cursorKey: String { "\(id).cursor.\(serverUrl ?? "")\n\(username ?? "")" }

    func login(username: String, password: String) async throws {
        SyncService.shared.cancelSync()
        try await authManager.login(username: username, password: password)
    }

    func logout() {
        SyncService.shared.cancelSync()
        authManager.logout()
    }

    override func onSelected() async throws {
        Logger.httpEngine.debug("Resetting HTTP sync cursor")
        UserDefaults.standard.removeObject(forKey: cursorKey)
    }

    override func sync() async throws {
        guard active else {
            Logger.httpEngine.warning("Cannot start HTTP sync without authentication")
            throw MankaiErrorCode.authMissingCredentialsOrServerUrl.makeError()
        }

        try await syncMutations(
            cursorKey: cursorKey,
            send: { request in
                let body = try JSONEncoder().encode(request)
                let (data, _) = try await self.authManager.post(path: "/sync", body: body)
                return data
            },
            isInvalidCursor: { error in
                (error as NSError).userInfo[MankaiErrorUserInfoKey.httpStatusCode] as? Int == 400
            })
    }
}
