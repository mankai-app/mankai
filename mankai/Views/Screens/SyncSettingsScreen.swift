//
//  SyncSettingsScreen.swift
//  mankai
//
//  Created by Travis XU on 10/12/2025.
//

import SwiftUI

struct SyncSettingsScreen: View {
    @ObservedObject private var syncService = SyncService.shared
    @State private var isClearingSyncCache = false
    @State private var syncError: String?
    @State private var showErrorAlert = false

    private var isBusy: Bool { syncService.isSyncing || isClearingSyncCache }

    var body: some View {
        List {
            SettingsHeaderView(
                image: Image(systemName: "arrow.triangle.2.circlepath"), color: .blue,
                title: String(localized: "sync"), description: String(localized: "syncDescription"))

            Section {
                Picker("syncEngine", selection: $syncService.engine) {
                    Text("none").tag(nil as SyncEngine?)
                    ForEach(SyncService.engines, id: \.id) { engine in
                        Text(engine.name).tag(engine as SyncEngine?)
                    }
                }
            }

            if let engine = syncService.engine {
                if engine is HttpEngine { HttpEngineConfigView() }

                Section("syncStatus") {
                    LabeledContent("status") {
                        HStack(spacing: 8) {
                            Circle().fill(engine.active ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(engine.active ? "active" : "inactive").foregroundColor(.secondary)
                        }
                    }

                    LabeledContent("lastSyncTime") {
                        if let lastSyncTime = syncService.lastSyncTime {
                            Text(lastSyncTime, style: .relative).foregroundColor(.secondary)
                        } else {
                            Text("never").foregroundColor(.secondary)
                        }
                    }

                    Button {
                        Task { await performSync() }
                    } label: {
                        HStack {
                            if syncService.isSyncing { ProgressView().padding(.trailing, 4) }
                            Text("syncNow")
                        }
                    }
                    .disabled(isBusy || !engine.active)
                }
            }

            if syncService.engine != nil {
                Section {
                    Button(role: .destructive) {
                        Task { await clearSyncCache() }
                    } label: {
                        HStack {
                            if isClearingSyncCache { ProgressView().padding(.trailing, 4) }
                            Text("clearSyncCache")
                        }
                    }
                    .disabled(isBusy)
                }
            }
        }
        .navigationTitle("sync").navigationBarTitleDisplayMode(.inline)
        .alert("syncFailed", isPresented: $showErrorAlert) {
            Button("ok", role: .cancel) {}
        } message: {
            if let syncError = syncError { Text(syncError) }
        }
    }

    private func performSync() async {
        syncError = nil

        do { try await syncService.sync() } catch {
            syncError = error.localizedDescription
            showErrorAlert = true
        }
    }

    private func clearSyncCache() async {
        isClearingSyncCache = true
        defer { isClearingSyncCache = false }
        syncError = nil

        do { try await syncService.onEngineChange() } catch {
            syncError = error.localizedDescription
            showErrorAlert = true
        }
    }
}

struct HttpEngineConfigView: View {
    @ObservedObject private var httpEngine = HttpEngine.shared
    @State private var serverUrl: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isLoggingIn = false
    @State private var showErrorAlert = false
    @State private var errorMessage: String?
    @State private var showLogoutConfirmation = false
    @State private var showResetConfirmation = false

    var body: some View {
        Group {
            Section("serverSettings") {
                if let serverUrl = httpEngine.serverUrl, !serverUrl.isEmpty {
                    LabeledContent("serverUrl") {
                        Text(serverUrl).foregroundColor(.secondary).textSelection(.enabled)
                    }

                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Text("resetConfigs")
                    }
                    .confirmationDialog(
                        "resetServerSettingsConfirmationMessage",
                        isPresented: $showResetConfirmation, titleVisibility: .visible
                    ) {
                        Button("reset", role: .destructive) {
                            httpEngine.serverUrl = nil
                            httpEngine.logout()
                            self.serverUrl = ""
                            username = ""
                            password = ""
                        }
                        Button("cancel", role: .cancel) {}
                    }
                } else {
                    TextField("serverUrl", text: $serverUrl).textContentType(.URL)
                        .keyboardType(.URL).autocapitalization(.none)

                    Button {
                        let trimmedServerUrl = serverUrl.trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        var cleanedUrl = trimmedServerUrl
                        var loginUsername: String?
                        var loginPassword: String?

                        if var components = URLComponents(string: trimmedServerUrl),
                            let queryItems = components.queryItems
                        {
                            loginUsername = queryItems.first(where: { $0.name == "username" })?
                                .value?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            loginPassword = queryItems.first(where: { $0.name == "password" })?
                                .value?
                                .trimmingCharacters(in: .whitespacesAndNewlines)

                            if loginUsername != nil || loginPassword != nil {
                                components.queryItems = components.queryItems?
                                    .filter { $0.name != "username" && $0.name != "password" }
                                if components.queryItems?.isEmpty ?? true { components.query = nil }
                                cleanedUrl = components.string ?? trimmedServerUrl
                            }
                        }

                        httpEngine.serverUrl = cleanedUrl
                        self.serverUrl = cleanedUrl

                        if let loginUsername = loginUsername, let loginPassword = loginPassword {
                            self.username = loginUsername
                            self.password = loginPassword

                            Task { await performLogin() }
                        }
                    } label: {
                        Text("saveConfigs")
                    }
                    .disabled(serverUrl.isEmpty)
                }
            }

            if httpEngine.serverUrl != nil {
                Section("credentials") {
                    if httpEngine.username != nil {
                        LabeledContent("username") {
                            Text(httpEngine.username ?? "").foregroundColor(.secondary)
                        }

                        Button(role: .destructive) {
                            showLogoutConfirmation = true
                        } label: {
                            Text("logout")
                        }
                        .confirmationDialog(
                            "logoutConfirmationMessage", isPresented: $showLogoutConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("logout", role: .destructive) {
                                httpEngine.logout()
                                username = ""
                                password = ""
                            }
                            Button("cancel", role: .cancel) {}
                        }
                    } else {
                        TextField("username", text: $username).textContentType(.username)
                            .keyboardType(.default).autocapitalization(.none)

                        SecureField("password", text: $password).textContentType(.password)

                        Button {
                            Task { await performLogin() }
                        } label: {
                            if isLoggingIn { ProgressView() } else { Text("login") }
                        }
                        .disabled(
                            username.isEmpty || password.isEmpty || serverUrl.isEmpty || isLoggingIn
                        )
                    }
                }
            }
        }
        .onAppear {
            serverUrl = httpEngine.serverUrl ?? ""
            username = httpEngine.username ?? ""
        }
        .alert("loginFailed", isPresented: $showErrorAlert) {
            Button("ok", role: .cancel) {}
        } message: {
            if let errorMessage = errorMessage { Text(errorMessage) }
        }
    }

    private func performLogin() async {
        isLoggingIn = true

        do {
            httpEngine.serverUrl = serverUrl
            try await httpEngine.login(username: username, password: password)

            password = ""
            username = httpEngine.username ?? ""
            serverUrl = httpEngine.serverUrl ?? ""
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }

        isLoggingIn = false
    }
}
