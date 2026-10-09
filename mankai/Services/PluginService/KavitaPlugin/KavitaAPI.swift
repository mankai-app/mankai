//
//  KavitaAPI.swift
//  mankai
//
//  Created by Travis XU on 9/10/2026.
//

import Foundation

/// Kavita REST API: https://wiki.kavitareader.com/guides/api/
struct KavitaConnectionConfiguration: Sendable {
    let baseURL: URL
    let username: String
    let password: String
    let apiKey: String

    init(baseUrl: String, username: String, password: String, apiKey: String) throws {
        guard let url = URL.normalizedHTTPURL(baseUrl, ensuresTrailingSlash: true) else {
            throw MankaiErrorCode.pluginKavitaInvalidUrl.makeError()
        }

        baseURL = url
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func url(path: [String], query: [URLQueryItem] = []) throws -> URL {
        let url = path.reduce(baseURL) { $0.appendingPathComponent($1) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw MankaiErrorCode.pluginKavitaInvalidUrl.makeError()
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw MankaiErrorCode.pluginKavitaInvalidUrl.makeError()
        }
        return url
    }

    func contains(_ url: URL) -> Bool {
        let basePath = baseURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        return url.scheme == baseURL.scheme && url.host == baseURL.host && url.port == baseURL.port
            && url.user == nil && url.password == nil
            && (url.path == basePath || url.path.hasPrefix(prefix))
    }

    func readerImageURL(_ url: URL, apiKey: String?) throws -> URL {
        guard contains(url) else { throw MankaiErrorCode.pluginKavitaInvalidUrl.makeError() }
        let imagePath = try self.url(path: ["api", "Reader", "image"]).path
        guard url.path.caseInsensitiveCompare(imagePath) == .orderedSame, let apiKey,
            !apiKey.isEmpty
        else { return url }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw MankaiErrorCode.pluginKavitaInvalidUrl.makeError()
        }
        // Keep credentials out of cached chapter URLs, attach the current account's key at send time.
        var query = (components.queryItems ?? [])
            .filter { $0.name.caseInsensitiveCompare("apiKey") != .orderedSame }
        query.append(URLQueryItem(name: "apiKey", value: apiKey))
        components.queryItems = query
        guard let url = components.url else {
            throw MankaiErrorCode.pluginKavitaInvalidUrl.makeError()
        }
        return url
    }
}

private final class KavitaSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let configuration: KavitaConnectionConfiguration

    init(configuration: KavitaConnectionConfiguration) { self.configuration = configuration }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(request.url.map(configuration.contains) == true ? request : nil) }
}

actor KavitaSession {
    nonisolated let configuration: KavitaConnectionConfiguration
    private let urlSession: URLSession
    private var token: String?
    private var readerApiKey: String?
    private var authenticationTask: Task<String, Error>?

    init(configuration: KavitaConnectionConfiguration) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieStorage = nil
        urlSession = URLSession(
            configuration: sessionConfiguration,
            delegate: KavitaSessionDelegate(configuration: configuration), delegateQueue: nil)
    }

    deinit { urlSession.invalidateAndCancel() }

    func validateConnection() async throws {
        let _: [KavitaLibrary] = try await request(path: ["api", "Library", "libraries"])
    }

    func seriesList(page: UInt, query: String?, statuses: [Int]) async throws -> [KavitaSeries] {
        // FilterV2: Formats = 21, PublicationStatus = 2, SeriesName = 1.
        // List fields use Contains = 5, the series name uses Matches = 7.
        // EPUBs require Kavita's book reader, image, archive and PDF series use page images.
        var statements: [[String: Any]] = [["field": 21, "comparison": 5, "value": "0,1,4"]]
        if !statuses.isEmpty {
            statements.append([
                "field": 2, "comparison": 5,
                "value": statuses.map(String.init).joined(separator: ",")
            ])
        }
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !query.isEmpty { statements.append(["field": 1, "comparison": 7, "value": query]) }
        let body = try JSONSerialization.data(withJSONObject: [
            "id": 0, "name": "", "statements": statements, "combination": 1,
            "sortOptions": ["sortField": 1, "isAscending": true], "entityType": 0, "limitTo": 0
        ])
        return try await request(
            path: ["api", "Series", "all-v2"], method: "POST",
            query: [
                URLQueryItem(name: "PageNumber", value: String(max(page, 1))),
                URLQueryItem(name: "PageSize", value: "30")
            ], body: body)
    }

    func series(id: String) async throws -> KavitaSeries {
        try await request(path: ["api", "Series", try identifier(id)])
    }

    func metadata(seriesId: String) async throws -> KavitaSeriesMetadata {
        try await request(
            path: ["api", "Series", "metadata"],
            query: [URLQueryItem(name: "seriesId", value: try identifier(seriesId))])
    }

    func volumes(seriesId: String) async throws -> [KavitaVolume] {
        try await request(
            path: ["api", "Series", "volumes"],
            query: [URLQueryItem(name: "seriesId", value: try identifier(seriesId))])
    }

    func chapterInfo(chapterId: String) async throws -> KavitaChapterInfo {
        // Prepare the chapter cache before requesting pages, including PDF extraction.
        try await request(
            path: ["api", "Reader", "chapter-info"],
            query: [
                URLQueryItem(name: "chapterId", value: try identifier(chapterId)),
                URLQueryItem(name: "extractPdf", value: "true")
            ])
    }

    func image(url: URL) async throws -> Data { try await data(url: url, accept: "image/*") }

    private func identifier(_ value: String) throws -> String {
        guard let id = Int(value), id > 0 else {
            throw MankaiErrorCode.pluginKavitaInvalidUrl.makeError()
        }
        return String(id)
    }

    private func bearerToken() async throws -> String {
        try Task.checkCancellation()
        if let token { return token }
        if let authenticationTask { return try await authenticationTask.value }

        // Concurrent cover and metadata requests share one login.
        let task = Task { try await self.authenticate() }
        authenticationTask = task
        defer { authenticationTask = nil }
        let value = try await task.value
        token = value
        return value
    }

    private func authenticate() async throws -> String {
        let url: URL
        let body: Data?
        if !configuration.apiKey.isEmpty {
            // Exchanging the key also supports servers predating x-api-key authentication.
            url = try configuration.url(
                path: ["api", "Plugin", "authenticate"],
                query: [
                    URLQueryItem(name: "apiKey", value: configuration.apiKey),
                    URLQueryItem(name: "pluginName", value: "Mankai")
                ])
            body = nil
        } else if !configuration.username.isEmpty {
            url = try configuration.url(path: ["api", "Account", "login"])
            body = try JSONSerialization.data(withJSONObject: [
                "username": configuration.username, "password": configuration.password
            ])
        } else {
            throw MankaiErrorCode.pluginKavitaInvalidCredentials.makeError()
        }

        let (data, response) = try await send(url: url, method: "POST", body: body)
        if response.statusCode == 400 || response.statusCode == 401 {
            throw MankaiErrorCode.pluginKavitaInvalidCredentials.makeError()
        }
        try validate(response)
        let user: KavitaUser = try decode(data)
        guard let token = user.token, !token.isEmpty else {
            throw MankaiErrorCode.pluginKavitaInvalidResponse.makeError()
        }
        // Password login returns the account's API key, Auth Key login uses the configured key.
        readerApiKey = configuration.apiKey.isEmpty ? user.apiKey : configuration.apiKey
        return token
    }

    private func request<T: Decodable & Sendable>(
        path: [String], method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil
    ) async throws -> T {
        let url = try configuration.url(path: path, query: query)
        let data = try await data(url: url, method: method, body: body)
        return try decode(data)
    }

    private func decode<T: Decodable & Sendable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw MankaiErrorCode.pluginKavitaInvalidResponse.makeError(underlyingError: error)
        }
    }

    private func data(
        url: URL, method: String = "GET", body: Data? = nil, accept: String = "application/json"
    ) async throws -> Data {
        // Check the URL before authenticating so credentials stay within this server's base path.
        guard configuration.contains(url) else {
            throw MankaiErrorCode.pluginKavitaInvalidUrl.makeError()
        }
        let currentToken = try await bearerToken()
        var (data, response) = try await send(
            url: url, method: method, body: body, accept: accept, token: currentToken)
        if response.statusCode == 401 {
            if token == currentToken { token = nil }
            let renewedToken = try await bearerToken()
            (data, response) = try await send(
                url: url, method: method, body: body, accept: accept, token: renewedToken)
        }
        try validate(response)
        return data
    }

    private func send(
        url: URL, method: String, body: Data? = nil, accept: String = "application/json",
        token: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard configuration.contains(url) else {
            throw MankaiErrorCode.pluginKavitaInvalidUrl.makeError()
        }
        try Task.checkCancellation()
        let requestURL =
            token == nil ? url : try configuration.readerImageURL(url, apiKey: readerApiKey)
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await urlSession.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MankaiErrorCode.pluginKavitaInvalidResponse.makeError()
        }
        return (data, response)
    }

    private func validate(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 {
            throw MankaiErrorCode.pluginKavitaInvalidCredentials.makeError()
        }
        guard (200...299).contains(response.statusCode) else {
            throw MankaiErrorCode.pluginKavitaRequestFailed.makeError(
                messageOverride:
                    "\(String(localized: "httpRequestFailed")) (\(response.statusCode))",
                additionalUserInfo: [MankaiErrorUserInfoKey.httpStatusCode: response.statusCode])
        }
    }
}

private struct KavitaLibrary: Decodable, Sendable { let id: Int }
private struct KavitaUser: Decodable, Sendable {
    let token: String?
    let apiKey: String?
}

struct KavitaSeries: Decodable, Sendable {
    let id: Int
    let name: String?
    let localizedName: String?
    let libraryId: Int
    let format: Int
    let lastChapterAddedUtc: String?
    let lastChapterAdded: String?
}

struct KavitaSeriesMetadata: Decodable, Sendable {
    let summary: String?
    let publicationStatus: Int?
    let writers: [Person]?
    let genres: [GenreTag]?

    struct Person: Decodable, Sendable { let name: String? }
    struct GenreTag: Decodable, Sendable { let title: String? }
}

struct KavitaVolume: Decodable, Sendable {
    let id: Int
    let name: String?
    let minNumber: Double?
    let number: Int?
    let chapters: [KavitaChapter]?

    var sortNumber: Double { minNumber ?? Double(number ?? 0) }
}

struct KavitaChapter: Decodable, Sendable {
    let id: Int
    let title: String?
    let titleName: String?
    let range: String?
    let number: String?
    let minNumber: Double?
    let sortOrder: Double?
    let isSpecial: Bool
    let pages: Int

    var sortNumber: Double { sortOrder ?? minNumber ?? number.flatMap(Double.init) ?? 0 }
}

struct KavitaChapterInfo: Decodable, Sendable {
    let seriesId: Int
    let seriesFormat: Int
    let pages: Int
}
