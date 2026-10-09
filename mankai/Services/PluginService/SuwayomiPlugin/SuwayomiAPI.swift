//
//  SuwayomiAPI.swift
//  mankai
//
//  Created by Travis XU on 9/10/2026.
//

import Foundation

/// Suwayomi GraphQL API: https://github.com/Suwayomi/Suwayomi-Server
struct SuwayomiConnectionConfiguration: Sendable {
    enum AuthMode: String, CaseIterable, Sendable {
        case none
        case basicAuth = "basic_auth"
        case simpleLogin = "simple_login"
        case uiLogin = "ui_login"
    }

    let baseURL: URL
    let username: String
    let password: String
    let authMode: AuthMode

    init(baseUrl: String, username: String, password: String, authMode: String) throws {
        guard let url = URL.normalizedHTTPURL(baseUrl, ensuresTrailingSlash: true) else {
            throw MankaiErrorCode.pluginSuwayomiInvalidUrl.makeError()
        }
        guard let mode = AuthMode(rawValue: authMode) else {
            throw MankaiErrorCode.pluginSuwayomiInvalidCredentials.makeError()
        }

        baseURL = url
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        self.authMode = mode
    }

    func url(path: [String]) -> URL { path.reduce(baseURL) { $0.appendingPathComponent($1) } }

    func contains(_ url: URL) -> Bool {
        let basePath = baseURL.standardized.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let path = url.standardized.path

        return url.scheme == baseURL.scheme && url.host == baseURL.host && url.port == baseURL.port
            && url.user == nil && url.password == nil && url.fragment == nil
            && (path == basePath || path.hasPrefix(prefix))
    }

    /// Page paths from Suwayomi may start at /api even when the server uses a subpath.
    func imageURL(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value),
            components.host == nil || components.scheme != nil, !value.hasPrefix("//"),
            components.fragment == nil
        else { throw MankaiErrorCode.pluginSuwayomiInvalidUrl.makeError() }

        let url: URL?
        if components.scheme != nil {
            url = URL.normalizedHTTPURL(value, allowsQuery: true)
        } else if baseURL.path != "/", value.hasPrefix(baseURL.path) {
            url = URL(string: value, relativeTo: baseURL)?.absoluteURL
        } else {
            url =
                URL(
                    string: value.hasPrefix("/") ? String(value.dropFirst()) : value,
                    relativeTo: baseURL)?
                .absoluteURL
        }

        guard let url, contains(url) else {
            throw MankaiErrorCode.pluginSuwayomiInvalidUrl.makeError()
        }
        return url
    }
}

private final class SuwayomiSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let configuration: SuwayomiConnectionConfiguration

    init(configuration: SuwayomiConnectionConfiguration) { self.configuration = configuration }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(request.url.map(configuration.contains) == true ? request : nil) }
}

actor SuwayomiSession {
    nonisolated let configuration: SuwayomiConnectionConfiguration
    private let urlSession: URLSession
    private var accessToken: String?
    private var refreshToken: String?
    private var loggedIn = false
    private var authenticationTask: Task<Void, Error>?

    init(
        configuration: SuwayomiConnectionConfiguration,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.configuration = configuration

        // UI login uses JWTs, cookies from a previous login must not authenticate
        // the login mutation itself, which Suwayomi rejects for logged-in users.
        if configuration.authMode != .simpleLogin {
            sessionConfiguration.httpShouldSetCookies = false
            sessionConfiguration.httpCookieStorage = nil
        }
        sessionConfiguration.urlCredentialStorage = nil

        // Keep cookies and authentication isolated between configured server accounts.
        urlSession = URLSession(
            configuration: sessionConfiguration,
            delegate: SuwayomiSessionDelegate(configuration: configuration), delegateQueue: nil)
    }

    deinit { urlSession.invalidateAndCancel() }

    private static let mangaFields = """
        id title status initialized author artist description genre realUrl lastFetchedAt
        latestChapter: highestNumberedChapter { id name }
        """

    func validateConnection() async throws {
        let _: MangaList = try await graphql(
            "query { mangas(first: 1, condition: { inLibrary: true }) { nodes { id title } } }")
    }

    func mangaList(page: UInt, query: String?, statuses: [String], isAuthor: Bool = false)
        async throws -> [SuwayomiManga]
    {
        guard page <= UInt(Int32.max / 30) else { return [] }
        var filter: [String: Any] = ["inLibrary": ["equalTo": true]]
        if !statuses.isEmpty { filter["status"] = ["in": statuses] }
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !query.isEmpty {
            if isAuthor {
                filter["or"] = [
                    ["author": ["includesInsensitive": query]],
                    ["artist": ["includesInsensitive": query]]
                ]
            } else {
                filter["title"] = ["includesInsensitive": query]
            }
        }

        let result: MangaList = try await graphql(
            """
            query($filter: MangaFilterInput!, $offset: Int!) {
                mangas(first: 30, offset: $offset, filter: $filter, order: [{ by: TITLE, byType: ASC }]) {
                    nodes { \(Self.mangaFields) }
                }
            }
            """, variables: ["filter": filter, "offset": Int(page > 0 ? page - 1 : 0) * 30])
        return result.mangas.nodes
    }

    func mangas(ids: [String]) async throws -> [SuwayomiManga] {
        let ids = try ids.map(numericID)
        var result: [SuwayomiManga] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            let response: MangaList = try await graphql(
                """
                query($ids: [Int!]!) {
                    mangas(first: 100, filter: { id: { in: $ids } }) {
                        nodes { \(Self.mangaFields) }
                    }
                }
                """, variables: ["ids": batch])
            result += response.mangas.nodes
        }
        let byID = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    func detailedManga(id: String) async throws -> SuwayomiMangaDetails {
        let id = try numericID(id)
        let stored: StoredMangaDetails = try await graphql(
            """
            query($id: Int!) {
                manga(id: $id) {
                    \(Self.mangaFields)
                    chapters { nodes { id name sourceOrder } }
                }
            }
            """, variables: ["id": id])
        let chapters = stored.manga.chapters?.nodes ?? []
        let manga = stored.manga
        if manga.initialized == true, !chapters.isEmpty {
            return SuwayomiMangaDetails(manga: manga, chapters: chapters)
        }

        // Fetch only missing metadata or chapters, cached server downloads remain readable even when the upstream extension or website is unavailable.
        let response: MangaDetails = try await graphql(
            """
            mutation($id: Int!, $fetchManga: Boolean!, $fetchChapters: Boolean!) {
                fetchMangaAndChapters(input: {
                    id: $id, fetchManga: $fetchManga, fetchChapters: $fetchChapters
                }) {
                    manga { \(Self.mangaFields) }
                    chapters { id name sourceOrder }
                }
            }
            """,
            variables: [
                "id": id, "fetchManga": manga.initialized != true, "fetchChapters": chapters.isEmpty
            ])
        return response.fetchMangaAndChapters
    }

    func pages(mangaId: String, chapterId: String) async throws -> [String] {
        let response: ChapterPages = try await graphql(
            """
            mutation($id: Int!) {
                fetchChapterPages(input: { chapterId: $id }) {
                    pages
                    chapter { mangaId }
                }
            }
            """, variables: ["id": try numericID(chapterId)])
        let payload = response.fetchChapterPages
        guard payload.chapter.mangaId == (try numericID(mangaId)), !payload.pages.isEmpty else {
            throw MankaiErrorCode.pluginSuwayomiInvalidResponse.makeError()
        }
        return try payload.pages.map { try configuration.imageURL($0).absoluteString }
    }

    func image(url: URL) async throws -> Data {
        try await authenticatedData(url: url, accept: "image/*")
    }

    private func numericID(_ value: String) throws -> Int {
        guard let id = Int(value), id > 0, id <= Int32.max else {
            throw MankaiErrorCode.pluginSuwayomiInvalidUrl.makeError()
        }
        return id
    }

    private func authenticate() async throws {
        switch configuration.authMode { case .none, .basicAuth: return case .uiLogin:
            if accessToken != nil { return }
            case .simpleLogin: if loggedIn { return }
        }
        if let authenticationTask { return try await authenticationTask.value }

        let task = Task { try await self.login() }
        authenticationTask = task
        defer { authenticationTask = nil }
        try await task.value
    }

    private func login() async throws {
        guard !configuration.username.isEmpty else {
            throw MankaiErrorCode.pluginSuwayomiInvalidCredentials.makeError()
        }
        switch configuration.authMode { case .uiLogin: try await loginWithTokens()

            case .simpleLogin:
                var form = URLComponents()
                form.queryItems = [
                    URLQueryItem(name: "user", value: configuration.username),
                    URLQueryItem(name: "pass", value: configuration.password)
                ]
                let body = Data(
                    (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8
                )
                _ = try await data(
                    url: configuration.url(path: ["login.html"]), body: body, accept: "text/html",
                    authenticated: false, contentType: "application/x-www-form-urlencoded")
                loggedIn = true

            case .none, .basicAuth: break
        }
    }

    private func loginWithTokens() async throws {
        if let refreshToken {
            do {
                let response: TokenRefresh = try await graphql(
                    """
                    mutation USER_REFRESH($refreshToken: String!) {
                        refreshToken(input: { refreshToken: $refreshToken }) { accessToken }
                    }
                    """, variables: ["refreshToken": refreshToken], requiresAuthentication: false)
                guard !response.refreshToken.accessToken.isEmpty else {
                    throw MankaiErrorCode.pluginSuwayomiInvalidResponse.makeError()
                }
                accessToken = response.refreshToken.accessToken
                return
            } catch
                where MankaiErrorCode.pluginSuwayomiInvalidCredentials.matches(error)
                || MankaiErrorCode.pluginSuwayomiRequestFailed.matches(error)
            {
                // An expired or revoked refresh token requires a fresh credential login.
                self.refreshToken = nil
            }
        }

        let response: Login = try await graphql(
            """
            mutation USER_LOGIN($username: String!, $password: String!) {
                login(input: { username: $username, password: $password }) {
                    accessToken
                    refreshToken
                }
            }
            """,
            variables: ["username": configuration.username, "password": configuration.password],
            requiresAuthentication: false)
        guard !response.login.accessToken.isEmpty, !response.login.refreshToken.isEmpty else {
            throw MankaiErrorCode.pluginSuwayomiInvalidResponse.makeError()
        }
        accessToken = response.login.accessToken
        refreshToken = response.login.refreshToken
    }

    private func graphql<T: Decodable & Sendable>(
        _ query: String, variables: [String: Any] = [:], requiresAuthentication: Bool = true
    ) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: [
            "query": query, "variables": variables
        ])
        let url = configuration.url(path: ["api", "graphql"])
        let responseData: Data
        if requiresAuthentication {
            responseData = try await authenticatedData(
                url: url, body: body, accept: "application/json")
        } else {
            responseData = try await data(
                url: url, body: body, accept: "application/json", authenticated: false)
        }
        return try decodeGraphQL(responseData)
    }

    private func decodeGraphQL<T: Decodable & Sendable>(_ data: Data) throws -> T {
        let errors: GraphQLErrors
        do { errors = try JSONDecoder().decode(GraphQLErrors.self, from: data) } catch {
            throw MankaiErrorCode.pluginSuwayomiInvalidResponse.makeError(underlyingError: error)
        }
        if let error = errors.errors?.first {
            if error.isAuthenticationFailure {
                throw MankaiErrorCode.pluginSuwayomiInvalidCredentials.makeError()
            }
            throw MankaiErrorCode.pluginSuwayomiRequestFailed.makeError(
                messageOverride: error.message)
        }
        let response: GraphQLResponse<T>
        do { response = try JSONDecoder().decode(GraphQLResponse<T>.self, from: data) } catch {
            throw MankaiErrorCode.pluginSuwayomiInvalidResponse.makeError(underlyingError: error)
        }
        guard let result = response.data else {
            throw MankaiErrorCode.pluginSuwayomiInvalidResponse.makeError()
        }
        return result
    }

    private func authenticatedData(url: URL, body: Data? = nil, accept: String) async throws -> Data
    {
        // Check the endpoint before logging in or attaching server credentials.
        guard configuration.contains(url) else {
            throw MankaiErrorCode.pluginSuwayomiInvalidUrl.makeError()
        }
        try await authenticate()
        let previousToken = accessToken

        func fetch() async throws -> Data {
            let result = try await data(url: url, body: body, accept: accept, authenticated: true)
            if accept == "application/json",
                let errors = try? JSONDecoder().decode(GraphQLErrors.self, from: result),
                errors.errors?.contains(where: \.isAuthenticationFailure) == true
            {
                throw MankaiErrorCode.pluginSuwayomiInvalidCredentials.makeError()
            }
            return result
        }

        do { return try await fetch() } catch
            where MankaiErrorCode.pluginSuwayomiInvalidCredentials.matches(error)
        {
            guard configuration.authMode == .uiLogin || configuration.authMode == .simpleLogin
            else { throw error }
            // Another concurrent request may already have renewed the access token.
            if previousToken == accessToken {
                accessToken = nil
                loggedIn = false
            }
            try await authenticate()
            return try await fetch()
        }
    }

    private func data(
        url: URL, body: Data? = nil, accept: String, authenticated: Bool,
        contentType: String = "application/json"
    ) async throws -> Data {
        guard configuration.contains(url) else {
            throw MankaiErrorCode.pluginSuwayomiInvalidUrl.makeError()
        }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.httpShouldHandleCookies = configuration.authMode == .simpleLogin
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        if authenticated {
            switch configuration.authMode { case .basicAuth:
                if !configuration.username.isEmpty {
                    let credentials = Data(
                        "\(configuration.username):\(configuration.password)".utf8
                    )
                    .base64EncodedString()
                    request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
                }
                case .uiLogin:
                    if let accessToken {
                        request.setValue(
                            "Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                    }
                case .none, .simpleLogin: break
            }
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MankaiErrorCode.pluginSuwayomiInvalidResponse.makeError()
        }
        if response.statusCode == 401 {
            throw MankaiErrorCode.pluginSuwayomiInvalidCredentials.makeError()
        }
        guard (200...299).contains(response.statusCode) else {
            throw MankaiErrorCode.pluginSuwayomiRequestFailed.makeError(
                messageOverride:
                    "\(String(localized: "httpRequestFailed")) (\(response.statusCode))",
                additionalUserInfo: [MankaiErrorUserInfoKey.httpStatusCode: response.statusCode])
        }
        return data
    }

    private struct MangaList: Decodable, Sendable {
        let mangas: Nodes
        struct Nodes: Decodable, Sendable { let nodes: [SuwayomiManga] }
    }

    private struct StoredMangaDetails: Decodable, Sendable { let manga: SuwayomiManga }

    private struct MangaDetails: Decodable, Sendable {
        let fetchMangaAndChapters: SuwayomiMangaDetails
    }

    private struct ChapterPages: Decodable, Sendable {
        let fetchChapterPages: Payload
        struct Payload: Decodable, Sendable {
            let pages: [String]
            let chapter: Owner
        }
        struct Owner: Decodable, Sendable { let mangaId: Int }
    }

    private struct Login: Decodable, Sendable {
        let login: Tokens
        struct Tokens: Decodable, Sendable {
            let accessToken: String
            let refreshToken: String
        }
    }

    private struct TokenRefresh: Decodable, Sendable {
        let refreshToken: Token
        struct Token: Decodable, Sendable { let accessToken: String }
    }

    private struct GraphQLResponse<Value: Decodable & Sendable>: Decodable, Sendable {
        let data: Value?
        let errors: [GraphQLError]?
    }

    private struct GraphQLErrors: Decodable { let errors: [GraphQLError]? }

    private struct GraphQLError: Decodable, Sendable {
        let message: String

        var isAuthenticationFailure: Bool {
            let message = message.lowercased()
            return message.contains("unauthorized") || message.contains("unauthenticated")
                || message.contains("incorrect username or password")
        }
    }
}

struct SuwayomiManga: Decodable, Sendable {
    let id: Int
    let title: String
    let status: String?
    let initialized: Bool?
    let author: String?
    let artist: String?
    let description: String?
    let genre: [String]?
    let realUrl: String?
    let lastFetchedAt: SuwayomiTimestamp?
    let latestChapter: SuwayomiChapter?
    let chapters: ChapterNodes?

    struct ChapterNodes: Decodable, Sendable { let nodes: [SuwayomiChapter] }
}

struct SuwayomiChapter: Decodable, Sendable {
    let id: Int
    let name: String
    let sourceOrder: Int?
}

struct SuwayomiMangaDetails: Decodable, Sendable {
    let manga: SuwayomiManga
    let chapters: [SuwayomiChapter]
}

/// GraphQL's LongString scalar serializes timestamps as strings, older responses may be numeric.
struct SuwayomiTimestamp: Decodable, Sendable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let number =
            (try? container.decode(Double.self))
            ?? (try? container.decode(String.self)).flatMap(Double.init)
        guard let number, number.isFinite else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid Suwayomi timestamp")
        }
        value = number
    }
}
