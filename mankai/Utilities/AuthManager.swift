//
//  AuthManager.swift
//  mankai
//
//  Created by Travis XU on 30/1/2026.
//

import Foundation

@MainActor final class AuthManager {
    private var _serverUrl: String?

    private var _username: String?
    private var _password: String?

    private var _refreshToken: String?
    private var _accessToken: String?

    private var refreshAccessTokenTask: Task<Void, Error>?
    private let refreshAccessTokenLock = NSLock()

    private var _id: String

    var postSave: (() -> Void)?
    var postLogin: (() -> Void)?
    var postLogout: (() -> Void)?

    var username: String? { return _username }

    var serverUrl: String? {
        get { return _serverUrl }
        set {
            _serverUrl = newValue
            if _serverUrl?.hasSuffix("/") == true { _serverUrl?.removeLast() }

            save()
        }
    }

    var loggedIn: Bool {
        return _username != nil && _password != nil && _refreshToken != nil && _accessToken != nil
    }

    init(
        id: String, postSave: (() -> Void)? = nil, postLogin: (() -> Void)? = nil,
        postLogout: (() -> Void)? = nil
    ) {
        _id = id
        self.postSave = postSave
        self.postLogin = postLogin
        self.postLogout = postLogout
        let defaults = UserDefaults.standard

        _username = defaults.string(forKey: "\(_id).username")
        _password = defaults.string(forKey: "\(_id).password")
        _refreshToken = defaults.string(forKey: "\(_id).refreshToken")
        _accessToken = defaults.string(forKey: "\(id).accessToken")
        _serverUrl = defaults.string(forKey: "\(id).serverUrl")

        Logger.authManager.debug("AuthManager initialized")
    }

    private func save() {
        let defaults = UserDefaults.standard

        defaults.set(_username, forKey: "\(_id).username")
        defaults.set(_password, forKey: "\(_id).password")
        defaults.set(_refreshToken, forKey: "\(_id).refreshToken")
        defaults.set(_accessToken, forKey: "\(_id).accessToken")
        defaults.set(_serverUrl, forKey: "\(_id).serverUrl")

        Logger.authManager.debug("AuthManager saved")
        postSave?()
    }

    func login(username: String, password: String) async throws {
        Logger.authManager.info("AuthManager logging in with username: \(username)")
        _username = username
        _password = password

        _refreshToken = nil
        _accessToken = nil

        try await getRefreshToken()
        try await refreshAccessToken()
        Logger.authManager.info("AuthManager login successful")

        postLogin?()
    }

    func logout() {
        Logger.authManager.info("AuthManager logging out")
        _username = nil
        _password = nil
        _refreshToken = nil
        _accessToken = nil

        save()
        postLogout?()
    }

    func isPasswordSame(password: String) -> Bool { return _password == password }

    private func getRefreshToken() async throws {
        Logger.authManager.debug("AuthManager getting refresh token")
        guard let username = _username, let password = _password, let serverUrl = _serverUrl else {
            Logger.authManager.error("AuthManager missing credentials or server URL")
            throw MankaiErrorCode.authMissingCredentialsOrServerUrl.makeError()
        }

        guard let url = URL(string: serverUrl + "/auth/login") else {
            Logger.authManager.error("AuthManager invalid server URL: \(serverUrl)")
            throw MankaiErrorCode.authInvalidServerUrl.makeError()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["username": username, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            Logger.authManager.error(
                "AuthManager login failed with status code: \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
            logout()
            throw MankaiErrorCode.authInvalidCredentials.makeError()
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            Logger.authManager.error("AuthManager invalid JSON response during login")
            throw MankaiErrorCode.authInvalidJsonResponse.makeError()
        }

        guard let refreshToken = json["refreshToken"] as? String else {
            Logger.authManager.error("AuthManager no refresh token in response")
            throw MankaiErrorCode.authNoRefreshTokenInResponse.makeError()
        }

        _refreshToken = refreshToken
        save()
        Logger.authManager.debug("AuthManager refresh token obtained")
    }

    private func refreshAccessToken() async throws {
        let task = getOrCreateRefreshAccessTokenTask()
        try await task.value
    }

    private func getOrCreateRefreshAccessTokenTask() -> Task<Void, Error> {
        refreshAccessTokenLock.lock()
        defer { refreshAccessTokenLock.unlock() }

        if let refreshAccessTokenTask { return refreshAccessTokenTask }

        let task: Task<Void, Error> = Task { [weak self] in
            defer { self?.clearRefreshAccessTokenTask() }

            guard let self else { return }
            try await self.performRefreshAccessToken()
        }

        refreshAccessTokenTask = task
        return task
    }

    private func clearRefreshAccessTokenTask() {
        refreshAccessTokenLock.lock()
        refreshAccessTokenTask = nil
        refreshAccessTokenLock.unlock()
    }

    private func performRefreshAccessToken() async throws {
        Logger.authManager.debug("AuthManager refreshing access token")
        guard let refreshToken = _refreshToken, let serverUrl = _serverUrl else {
            Logger.authManager.error("AuthManager missing refresh token or server URL")
            throw MankaiErrorCode.authMissingRefreshTokenOrServerUrl.makeError()
        }

        guard let url = URL(string: serverUrl + "/auth/refresh") else {
            Logger.authManager.error("AuthManager invalid server URL: \(serverUrl)")
            throw MankaiErrorCode.authInvalidServerUrl.makeError()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["refreshToken": refreshToken]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            Logger.authManager.error("AuthManager invalid response during token refresh")
            throw MankaiErrorCode.authInvalidResponse.makeError()
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            // maybe the refresh token is expired, try to get a new one
            Logger.authManager.warning("AuthManager refresh token expired, trying to re-login")
            try await getRefreshToken()
            return try await performRefreshAccessToken()
        }

        guard httpResponse.statusCode == 200 else {
            Logger.authManager.error(
                "AuthManager refresh failed with status code: \(httpResponse.statusCode)")
            throw MankaiErrorCode.authRefreshFailed.makeError()
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            Logger.authManager.error("AuthManager invalid JSON response during token refresh")
            throw MankaiErrorCode.authInvalidJsonResponse.makeError()
        }

        guard let accessToken = json["accessToken"] as? String else {
            Logger.authManager.error("AuthManager no access token in response")
            throw MankaiErrorCode.authNoAccessTokenInResponse.makeError()
        }

        _accessToken = accessToken
        save()
        Logger.authManager.debug("AuthManager access token refreshed")
    }

    // MARK: - High-level HTTP Methods

    func get(path: String, query: [String: String]? = nil) async throws -> (Data, HTTPURLResponse) {
        return try await request(method: "GET", path: path, query: query, body: nil)
    }

    func post(path: String, query: [String: String]? = nil, body: Data? = nil) async throws -> (
        Data, HTTPURLResponse
    ) { return try await request(method: "POST", path: path, query: query, body: body) }

    func patch(path: String, query: [String: String]? = nil, body: Data? = nil) async throws -> (
        Data, HTTPURLResponse
    ) { return try await request(method: "PATCH", path: path, query: query, body: body) }

    func put(path: String, query: [String: String]? = nil, body: Data? = nil) async throws -> (
        Data, HTTPURLResponse
    ) { return try await request(method: "PUT", path: path, query: query, body: body) }

    func delete(path: String, query: [String: String]? = nil) async throws -> (
        Data, HTTPURLResponse
    ) { return try await request(method: "DELETE", path: path, query: query, body: nil) }

    func request(
        method: String, path: String, query: [String: String]? = nil, body: Data? = nil,
        contentType: String = "application/json", retry: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        Logger.authManager.debug("AuthManager request: \(method) \(path)")
        guard let serverUrl = _serverUrl else {
            Logger.authManager.error("AuthManager missing server URL")
            throw MankaiErrorCode.authMissingServerUrl.makeError()
        }

        var urlString = serverUrl + path

        if let query = query, !query.isEmpty {
            let queryString =
                query.map {
                    "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
                }
                .joined(separator: "&")
            urlString += "?" + queryString
        }

        guard let url = URL(string: urlString) else {
            Logger.authManager.error("AuthManager invalid URL: \(urlString)")
            throw MankaiErrorCode.authInvalidUrl.makeError()
        }

        Logger.authManager.debug("AuthManager request URL: \(url)")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")

        if let accessToken = _accessToken {
            urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        if let body = body { urlRequest.httpBody = body }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403, retry,
                _refreshToken != nil
            {
                Logger.authManager.warning(
                    "AuthManager request 401/403, retrying with token refresh")
                try await refreshAccessToken()
                return try await request(
                    method: method, path: path, query: query, body: body, contentType: contentType,
                    retry: false)
            }

            if (200...299).contains(httpResponse.statusCode) {
                return (data, httpResponse)
            } else {
                let errorMsg =
                    String(data: data, encoding: .utf8) ?? "HTTP error \(httpResponse.statusCode)"
                Logger.authManager.error("AuthManager request failed: \(errorMsg)")
                throw MankaiErrorCode.authRequestFailed.makeError(
                    messageOverride: errorMsg,
                    additionalUserInfo: [
                        MankaiErrorUserInfoKey.httpStatusCode: httpResponse.statusCode
                    ])
            }
        } else {
            Logger.authManager.error("AuthManager invalid response type")
            throw MankaiErrorCode.authInvalidResponse.makeError()
        }
    }
}
