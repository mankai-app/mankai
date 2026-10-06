//
//  SupabaseEngine.swift
//  mankai
//
//  Created by Travis XU on 1/2/2026.
//

import Foundation
import Supabase

final class SupabaseEngine: MutationSyncEngine {
    static let shared = SupabaseEngine()

    private var supabase: SupabaseClient?
    private var authTask: Task<Void, Never>?
    private var url: String?
    private var key: String?

    override var id: String { "SupabaseEngine" }
    override var name: String { String(localized: "supabaseEngine") }
    override var active: Bool { currentUser != nil }

    var isConfigured: Bool { supabase != nil }
    var currentUrl: String? { url }
    var currentKey: String? { key }
    var currentUser: User? { supabase?.auth.currentUser }

    private var cursorKey: String {
        "\(id).cursor.\(url ?? "")\n\(currentUser?.id.uuidString ?? "")"
    }

    override private init() {
        super.init()
        let defaults = UserDefaults.standard
        if let url = defaults.string(forKey: "SupabaseEngine.url"),
            let key = defaults.string(forKey: "SupabaseEngine.key"),
            let validURL = URL.normalizedHTTPURL(url), !key.isEmpty
        {
            self.url = url
            self.key = key
            setClient(url: validURL, key: key)
        }
    }

    func configClient(url: String, key: String) throws {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let validURL = URL.normalizedHTTPURL(url) else {
            throw MankaiErrorCode.syncSupabaseInvalidUrl.makeError()
        }
        guard !key.isEmpty else { throw MankaiErrorCode.syncSupabaseNotConfigured.makeError() }
        guard url != self.url || key != self.key else { return }

        resetClient()
        self.url = url
        self.key = key
        setClient(url: validURL, key: key)
        UserDefaults.standard.set(url, forKey: "SupabaseEngine.url")
        UserDefaults.standard.set(key, forKey: "SupabaseEngine.key")
        objectWillChange.send()
    }

    private func setClient(url: URL, key: String) {
        // The RPC protocol uses camelCase keys, including its nested mutation payloads.
        let client = SupabaseClient(
            supabaseURL: url, supabaseKey: key,
            options: SupabaseClientOptions(
                db: .init(encoder: JSONEncoder(), decoder: JSONDecoder()),
                auth: .init(autoRefreshToken: true, emitLocalSessionAsInitialSession: true)))
        supabase = client
        authTask = Task { [weak self] in
            var userID = client.auth.currentUser?.id
            for await (_, session) in client.auth.authStateChanges {
                guard !Task.isCancelled, let self, self.supabase === client else { break }
                self.objectWillChange.send()
                guard userID != session?.user.id else { continue }
                userID = session?.user.id
                guard SyncService.shared.engine?.id == self.id else { continue }
                SyncService.shared.cancelSync()
                if let userID {
                    Task {
                        guard self.supabase === client, self.currentUser?.id == userID,
                            SyncService.shared.engine?.id == self.id
                        else { return }
                        try? await SyncService.shared.onEngineChange()
                    }
                }
            }
        }
    }

    func resetClient() {
        SyncService.shared.cancelSync()
        authTask?.cancel()
        authTask = nil
        supabase = nil
        url = nil
        key = nil
        UserDefaults.standard.removeObject(forKey: "SupabaseEngine.url")
        UserDefaults.standard.removeObject(forKey: "SupabaseEngine.key")
        objectWillChange.send()
    }

    struct AuthSettings: Decodable, Sendable {
        let external: [String: Bool]

        var enabledOAuthProviders: [Provider] {
            // Email uses password or OTP APIs, not signInWithOAuth.
            Provider.allCases.filter { $0 != .email && external[$0.rawValue] == true }
        }

        var emailEnabled: Bool { external["email"] == true }
        var phoneEnabled: Bool { external["phone"] == true }
    }

    /// Reads the public Auth settings without requiring a user session.
    func fetchAuthSettings() async throws -> AuthSettings {
        guard let client = supabase, let url, let key, let baseURL = URL.normalizedHTTPURL(url)
        else { throw MankaiErrorCode.syncSupabaseNotConfigured.makeError() }
        var request = URLRequest(
            url: baseURL.appendingPathComponent("auth/v1/settings"),
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Logger.supabaseEngine.debug("Fetching Supabase authentication settings")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard supabase === client else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else {
            throw MankaiErrorCode.syncSupabaseAuthSettingsFailed.makeError()
        }
        guard (200...299).contains(response.statusCode) else {
            throw MankaiErrorCode.syncSupabaseAuthSettingsFailed.makeError(additionalUserInfo: [
                MankaiErrorUserInfoKey.httpStatusCode: response.statusCode
            ])
        }

        do {
            let settings = try JSONDecoder().decode(AuthSettings.self, from: data)
            Logger.supabaseEngine.debug(
                "Discovered \(settings.enabledOAuthProviders.count) enabled OAuth providers")
            return settings
        } catch {
            throw MankaiErrorCode.syncSupabaseAuthSettingsFailed.makeError(underlyingError: error)
        }
    }

    func login(provider: Provider) async throws {
        guard let client = supabase else {
            throw MankaiErrorCode.syncSupabaseNotConfigured.makeError()
        }
        SyncService.shared.cancelSync()
        Logger.supabaseEngine.info("Logging in with provider: \(provider)")
        try await client.auth.signInWithOAuth(
            provider: provider, redirectTo: URL(string: "mankai://login-callback")!)
        objectWillChange.send()
    }

    func logout() async throws {
        guard let client = supabase else {
            throw MankaiErrorCode.syncSupabaseNotConfigured.makeError()
        }
        SyncService.shared.cancelSync()
        Logger.supabaseEngine.info("Logging out")
        try await client.auth.signOut(scope: .local)
        objectWillChange.send()
    }

    override func onSelected() async throws {
        Logger.supabaseEngine.debug("Resetting Supabase sync cursor")
        UserDefaults.standard.removeObject(forKey: cursorKey)
    }

    private struct RPCRequest: Encodable, Sendable { let request: SyncRequest }

    override func sync() async throws {
        guard let client = supabase, let userID = currentUser?.id else {
            throw MankaiErrorCode.syncSupabaseNotReady.makeError()
        }
        Logger.supabaseEngine.debug("Starting Supabase sync")
        try await syncMutations(
            cursorKey: cursorKey,
            send: { request in
                guard self.supabase === client, client.auth.currentUser?.id == userID else {
                    throw CancellationError()
                }
                let response = try await client.rpc("sync", params: RPCRequest(request: request))
                    .execute()
                guard self.supabase === client, client.auth.currentUser?.id == userID else {
                    throw CancellationError()
                }
                return response.data
            },
            isInvalidCursor: { error in
                guard let error = error as? PostgrestError else { return false }
                return error.code == "22023" && error.message.hasPrefix("Invalid cursor")
            })
        Logger.supabaseEngine.info("Supabase sync completed")
    }

    isolated deinit { authTask?.cancel() }
}
