//
//  RemoteImageProcessor.swift
//  mankai
//
//  Created by Travis XU on 28/9/2026.
//

import Combine
import CoreImage
import Foundation
import ReerCodable

@Codable private struct RemoteImageProcessorMetadata {
    let id: String
    let name: String?
    let version: String?
    let description: String?
    @DecodingDefault([]) let authors: [String]
    let repository: String?
    @DecodingDefault(false) let authenticationEnabled: Bool
    @DecodingDefault([]) let configs: [Config]
}

/// Sends pipeline images to a server implementing `docs/imageprocessor/api.md`.
final class RemoteImageProcessor: ImageProcessor, ObservableObject, @unchecked Sendable {
    static let type = "remote"
    static let titleKey: LocalizedStringResource = "remoteImageProcessor"
    static let descriptionKey: LocalizedStringResource = "remoteImageProcessorDescription"
    private static let usernameKey = "mankai.authentication.username"
    private static let passwordKey = "mankai.authentication.password"

    let isFast = false

    let instanceID: String
    let serverURL: String
    private let metadata: RemoteImageProcessorMetadata
    @MainActor private var storedConfigValues: [ConfigValue]
    private let authManager: AuthManager
    @MainActor private(set) var username: String
    @MainActor private(set) var password: String

    var title: String { metadata.name ?? metadata.id }
    var description: String { metadata.description ?? String(localized: Self.descriptionKey) }

    var remoteID: String { metadata.id }
    var version: String? { metadata.version }
    var authors: [String] { metadata.authors }
    var repository: String? { metadata.repository }
    var authenticationEnabled: Bool { metadata.authenticationEnabled }

    @MainActor var configs: [Config] {
        var result: [Config] = []
        if authenticationEnabled {
            result.append(
                Config(key: Self.usernameKey, name: "username", type: .text, defaultValue: ""))
            result.append(
                Config(key: Self.passwordKey, name: "password", type: .password, defaultValue: ""))
        }
        result.append(contentsOf: metadata.configs)
        return result
    }

    @MainActor var configValues: [ConfigValue] {
        var result = storedConfigValues
        if authenticationEnabled {
            result.append(ConfigValue(key: Self.usernameKey, value: username))
            result.append(ConfigValue(key: Self.passwordKey, value: password))
        }
        return result
    }

    @MainActor private init(
        instanceID: String, serverURL: String, metadata: RemoteImageProcessorMetadata,
        configValues: [ConfigValue], username: String = "", password: String = ""
    ) {
        self.instanceID = instanceID
        self.serverURL = serverURL
        self.metadata = metadata
        storedConfigValues = configValues
        authManager = AuthManager(id: "RemoteImageProcessor.\(instanceID)")
        self.username = username
        self.password = password
    }

    /// Fetches and validates the server metadata at the supplied URL.
    @MainActor static func fromURL(_ urlString: String) async throws -> Self {
        guard
            let metadataURL = URL.normalizedHTTPURL(
                urlString, allowsQuery: true, allowsFragment: true)
        else { throw MankaiErrorCode.imageProcessingRemoteInvalidURL.makeError() }

        let (data, response) = try await URLSession.shared.data(from: metadataURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MankaiErrorCode.imageProcessingRemoteInvalidResponse.makeError()
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseMessage = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MankaiErrorCode.imageProcessingRemoteRequestFailed.makeError(
                messageOverride: responseMessage?.isEmpty == false ? responseMessage : nil,
                additionalUserInfo: [MankaiErrorUserInfoKey.httpStatusCode: httpResponse.statusCode]
            )
        }

        let metadata: RemoteImageProcessorMetadata
        do { metadata = try RemoteImageProcessorMetadata.decoded(from: data) } catch {
            throw MankaiErrorCode.imageProcessingRemoteInvalidMetadata.makeError(
                underlyingError: error)
        }
        let id = metadata.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let configKeys = metadata.configs.map(\.key)
        guard !id.isEmpty, configKeys.allSatisfy({ !$0.isEmpty }),
            Set(configKeys).count == configKeys.count
        else { throw MankaiErrorCode.imageProcessingRemoteInvalidMetadata.makeError() }

        var components = URLComponents(url: metadataURL, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        components?.queryItems = nil
        components?.fragment = nil
        guard var baseURL = components?.string else {
            throw MankaiErrorCode.imageProcessingRemoteInvalidURL.makeError()
        }
        while baseURL.hasSuffix("/") { baseURL.removeLast() }

        let configByKey = Dictionary(uniqueKeysWithValues: metadata.configs.map { ($0.key, $0) })
        let queryValues = queryItems.compactMap { item -> ConfigValue? in
            guard let config = configByKey[item.name] else { return nil }
            return ConfigValue(key: config.key, value: config.type.parseValue(item.value ?? ""))
        }

        return Self(
            instanceID: UUID().uuidString, serverURL: baseURL, metadata: metadata,
            configValues: queryValues)
    }

    @MainActor func encode(id: String, order: Int, isEnabled: Bool) throws -> ImageProcessorModel {
        let configuration = Configuration(
            serverURL: serverURL, metadata: metadata, configValues: storedConfigValues,
            username: username, password: password)
        let data = try configuration.encodedData()
        return ImageProcessorModel(
            id: id, type: Self.type, order: order, isEnabled: isEnabled,
            configuration: String(decoding: data, as: UTF8.self))
    }

    @MainActor static func decode(_ model: ImageProcessorModel) throws -> any ImageProcessor {
        let configuration: Configuration
        do { configuration = try Configuration.decoded(from: Data(model.configuration.utf8)) } catch
        {
            throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError(
                underlyingError: error)
        }

        return Self(
            instanceID: model.id, serverURL: configuration.serverURL,
            metadata: configuration.metadata, configValues: configuration.configValues,
            username: configuration.username, password: configuration.password)
    }

    @MainActor func getConfig(_ key: String) -> Any {
        if key == Self.usernameKey { return username }
        if key == Self.passwordKey { return password }
        return storedConfigValues.first(where: { $0.key == key })?.value ?? NSNull()
    }

    @MainActor func setConfig(key: String, value: Any) throws {
        if key == Self.usernameKey {
            username = value as? String ?? ""
        } else if key == Self.passwordKey {
            password = value as? String ?? ""
        } else {
            guard metadata.configs.contains(where: { $0.key == key }) else {
                throw MankaiErrorCode.imageProcessingInvalidConfiguration.makeError()
            }
            storedConfigValues.removeAll { $0.key == key }
            storedConfigValues.append(ConfigValue(key: key, value: value))
        }
        objectWillChange.send()
        ImageProcessingService.shared.update(id: instanceID, processor: self)
    }

    @MainActor func resetConfigs() throws {
        storedConfigValues = []
        username = ""
        password = ""
        objectWillChange.send()
        ImageProcessingService.shared.update(id: instanceID, processor: self)
    }

    func process(image: CIImage, pointSize: CGSize) async throws -> CIImage {
        try Task.checkCancellation()
        let imageData = try Self.pngData(for: image)
        let multipartForm = try await MainActor.run {
            let context = ProcessContext(
                pointSize: .init(width: Double(pointSize.width), height: Double(pointSize.height)))

            var form = MultipartFormData()
            try form.addJSON(storedConfigValues, name: "configs")
            try form.addJSON(context, name: "context")
            form.addFile(imageData, name: "image", filename: "image.png", contentType: "image/png")
            return form
        }

        let result = try await request(
            body: multipartForm.encodedData(), contentType: multipartForm.contentType)

        try Task.checkCancellation()
        guard
            result.1.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("image/")
                == true,
            let processedImage = CIImage(data: result.0, options: [.applyOrientationProperty: true])
        else { throw MankaiErrorCode.imageProcessingRemoteInvalidResponse.makeError() }
        return processedImage
    }

    @MainActor private func request(body: Data, contentType: String) async throws -> (
        Data, HTTPURLResponse
    ) {
        if authManager.serverUrl != serverURL { authManager.serverUrl = serverURL }

        if authenticationEnabled {
            guard !username.isEmpty, !password.isEmpty else {
                throw MankaiErrorCode.authMissingCredentialsOrServerUrl.makeError()
            }
            if !authManager.loggedIn || authManager.username != username
                || !authManager.isPasswordSame(password: password)
            {
                try await authManager.login(username: username, password: password)
            }
        }

        return try await authManager.request(
            method: "POST", path: "/process", body: body, contentType: contentType)
    }

    private static func pngData(for image: CIImage) throws -> Data {
        let extent = image.extent.integral
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let data = renderingContext.pngRepresentation(
                of: image, format: .RGBA8, colorSpace: colorSpace)
        else { throw MankaiErrorCode.imageProcessingFailedToRender.makeError() }
        return data
    }

    private static let renderingContext = CIContext(options: [.cacheIntermediates: false])

    private struct Configuration: Codable {
        let serverURL: String
        let metadata: RemoteImageProcessorMetadata
        let configValues: [ConfigValue]
        let username: String
        let password: String
    }

    private struct ProcessContext: Codable {
        let pointSize: PointSize

        struct PointSize: Codable {
            let width: Double
            let height: Double
        }
    }
}

@MainActor extension RemoteImageProcessor: Configurable {}
