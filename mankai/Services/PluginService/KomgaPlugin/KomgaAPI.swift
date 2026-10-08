//
//  KomgaAPI.swift
//  mankai
//
//  Created by Travis XU on 8/10/2026.
//

import Foundation

/// Komga REST API: https://komga.org/docs/openapi/komga-api/
struct KomgaConnectionConfiguration: Sendable {
    let baseURL: URL
    let username: String
    let password: String
    let apiKey: String

    init(baseUrl: String, username: String, password: String, apiKey: String) throws {
        guard let url = URL.normalizedHTTPURL(baseUrl, ensuresTrailingSlash: true) else {
            throw MankaiErrorCode.pluginKomgaInvalidUrl.makeError()
        }

        baseURL = url
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func url(path: [String]) -> URL { path.reduce(baseURL) { $0.appendingPathComponent($1) } }

    func contains(_ url: URL) -> Bool {
        let basePath = baseURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"

        return url.scheme == baseURL.scheme && url.host == baseURL.host && url.port == baseURL.port
            && url.user == nil && url.password == nil
            && (url.path == basePath || url.path.hasPrefix(prefix))
    }
}

private final class KomgaSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let configuration: KomgaConnectionConfiguration

    init(configuration: KomgaConnectionConfiguration) { self.configuration = configuration }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(request.url.map(configuration.contains) == true ? request : nil) }
}

actor KomgaSession {
    nonisolated let configuration: KomgaConnectionConfiguration
    private let urlSession: URLSession

    init(configuration: KomgaConnectionConfiguration) {
        self.configuration = configuration

        // Each plugin may use a different account on the same server.
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieStorage = nil

        urlSession = URLSession(
            configuration: sessionConfiguration,
            delegate: KomgaSessionDelegate(configuration: configuration), delegateQueue: nil)
    }

    deinit { urlSession.invalidateAndCancel() }

    func validateConnection() async throws {
        let _: [KomgaLibrary] = try await request(path: ["api", "v1", "libraries"])
    }

    func seriesList(page: UInt, query: String?, statuses: [String], isAuthor: Bool = false)
        async throws -> [KomgaSeries]
    {
        var conditions: [[String: Any]] = [["deleted": ["operator": "isFalse"]]]

        if !statuses.isEmpty {
            conditions.append([
                "anyOf": statuses.map { ["seriesStatus": ["operator": "is", "value": $0]] }
            ])
        }

        var body: [String: Any] = [:]
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !query.isEmpty {
            if isAuthor {
                conditions.append(["author": ["operator": "is", "value": ["name": query]]])
            } else {
                body["fullTextSearch"] = query
            }
        }

        body["condition"] = ["allOf": conditions]

        let result: KomgaPage<KomgaSeries> = try await request(
            path: ["api", "v1", "series", "list"], method: "POST",
            query: [
                URLQueryItem(name: "page", value: String(page > 0 ? page - 1 : 0)),
                URLQueryItem(name: "size", value: "30"),
                URLQueryItem(
                    name: "sort",
                    value: !query.isEmpty && !isAuthor ? "relevance,asc" : "metadata.titleSort,asc")
            ], body: JSONSerialization.data(withJSONObject: body))

        return result.content
    }

    func series(id: String) async throws -> KomgaSeries {
        try await request(path: ["api", "v1", "series", id])
    }

    func books(seriesId: String, latestOnly: Bool = false) async throws -> [KomgaBook] {
        let body = try JSONSerialization.data(withJSONObject: [
            "condition": [
                "allOf": [
                    ["seriesId": ["operator": "is", "value": seriesId]],
                    ["deleted": ["operator": "isFalse"]],
                    ["mediaStatus": ["operator": "is", "value": "READY"]]
                ]
            ]
        ])

        var books: [KomgaBook] = []
        var page = 0

        while true {
            try Task.checkCancellation()

            let result: KomgaPage<KomgaBook> = try await request(
                path: ["api", "v1", "books", "list"], method: "POST",
                query: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "size", value: latestOnly ? "1" : "100"),
                    URLQueryItem(
                        name: "sort",
                        value: latestOnly ? "metadata.numberSort,desc" : "metadata.numberSort,asc")
                ], body: body)

            books += result.content

            if latestOnly || result.last || result.content.isEmpty { return books }

            page += 1
        }
    }

    func pages(bookId: String) async throws -> [KomgaBookPage] {
        try await request(path: ["api", "v1", "books", bookId, "pages"])
    }

    func image(url: URL) async throws -> Data { try await data(url: url, accept: "image/*") }

    private func request<T: Decodable & Sendable>(
        path: [String], method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil
    ) async throws -> T {
        guard
            var components = URLComponents(
                url: configuration.url(path: path), resolvingAgainstBaseURL: false)
        else { throw MankaiErrorCode.pluginKomgaInvalidUrl.makeError() }

        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw MankaiErrorCode.pluginKomgaInvalidUrl.makeError()
        }

        let data = try await data(url: url, method: method, body: body)

        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw MankaiErrorCode.pluginKomgaInvalidResponse.makeError(underlyingError: error)
        }
    }

    private func data(
        url: URL, method: String = "GET", body: Data? = nil, accept: String = "application/json"
    ) async throws -> Data {
        guard configuration.contains(url) else {
            throw MankaiErrorCode.pluginKomgaInvalidUrl.makeError()
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        if !configuration.apiKey.isEmpty {
            request.setValue(configuration.apiKey, forHTTPHeaderField: "X-API-Key")
        } else if !configuration.username.isEmpty {
            let credentials = Data("\(configuration.username):\(configuration.password)".utf8)
                .base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        } else {
            throw MankaiErrorCode.pluginKomgaInvalidCredentials.makeError()
        }

        let (data, response) = try await urlSession.data(for: request)

        guard let response = response as? HTTPURLResponse else {
            throw MankaiErrorCode.pluginKomgaInvalidResponse.makeError()
        }

        if response.statusCode == 401 {
            throw MankaiErrorCode.pluginKomgaInvalidCredentials.makeError()
        }

        guard (200...299).contains(response.statusCode) else {
            throw MankaiErrorCode.pluginKomgaRequestFailed.makeError(
                messageOverride:
                    "\(String(localized: "httpRequestFailed")) (\(response.statusCode))",
                additionalUserInfo: [MankaiErrorUserInfoKey.httpStatusCode: response.statusCode])
        }

        return data
    }
}

private struct KomgaLibrary: Decodable, Sendable { let id: String }

private struct KomgaPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let content: [Item]
    let last: Bool
}

struct KomgaSeries: Decodable, Sendable {
    let id: String
    let name: String
    let lastModified: String?
    let metadata: Metadata
    let booksMetadata: BooksMetadata?

    struct Metadata: Decodable, Sendable {
        let title: String?
        let status: String?
        let summary: String?
        let readingDirection: String?
        let genres: [String]?
    }

    struct BooksMetadata: Decodable, Sendable {
        let authors: [Author]?
        let summary: String?
    }

    struct Author: Decodable, Sendable { let name: String }
}

struct KomgaBook: Decodable, Sendable {
    let id: String
    let name: String
    let metadata: Metadata

    struct Metadata: Decodable, Sendable { let title: String? }
}

struct KomgaBookPage: Decodable, Sendable { let number: Int }
