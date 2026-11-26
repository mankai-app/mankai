//
//  FtpSession.swift
//  mankai
//
//  Created by Travis XU on 26/11/2026.
//

import Foundation
import os

enum FtpTransferProtocol: String, CaseIterable, Codable, Sendable {
    case ftp
    case sftp
    case ftpsExplicit = "ftps-explicit"
    case ftps

    var defaultPort: Int {
        switch self { case .ftp, .ftpsExplicit: 21 case .sftp: 22 case .ftps: 990
        }
    }

    var scheme: String { self == .ftpsExplicit ? "ftp" : rawValue }

    var usesTLS: Bool { self == .ftpsExplicit || self == .ftps }

    var tag: String { usesTLS ? "FTPS" : rawValue.uppercased() }
}

struct FtpConnectionConfiguration: Sendable {
    let transferProtocol: FtpTransferProtocol
    let host: String
    let port: Int
    let username: String
    let password: String

    init(
        transferProtocol: FtpTransferProtocol, host: String, port: Int, username: String,
        password: String
    ) throws {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalidCharacters = CharacterSet(charactersIn: "\0\r\n")
        guard let host = URL.normalizedHost(host), URL.isValidPort(port),
            transferProtocol != .sftp || !username.isEmpty,
            username.rangeOfCharacter(from: invalidCharacters) == nil,
            password.rangeOfCharacter(from: invalidCharacters) == nil
        else { throw MankaiErrorCode.browseFtpInvalidConnectionConfiguration.makeError() }

        self.transferProtocol = transferProtocol
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    func url(path: String, isDirectory: Bool) throws -> URL {
        guard
            path.isEmpty
                || path.split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ PathUtilities.isValidComponent(String($0)) }),
            path.rangeOfCharacter(from: .newlines) == nil,
            let encodedPath = path.addingPercentEncoding(withAllowedCharacters: Self.pathCharacters)
        else { throw MankaiErrorCode.browseFtpInvalidPlugin.makeError() }

        var components = URLComponents()
        components.scheme = transferProtocol.scheme
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        // curl's /~/ prefix keeps SFTP paths relative to the login directory, like FTP paths.
        let base = transferProtocol == .sftp ? "/~/" : "/"
        let suffix = isDirectory && !path.isEmpty ? "/" : ""
        components.percentEncodedPath = base + encodedPath + suffix
        guard let url = components.url, url.host?.isEmpty == false else {
            throw MankaiErrorCode.browseFtpInvalidConnectionConfiguration.makeError()
        }
        return url
    }

    private static let pathCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
}

/// Serializes use of a libcurl easy handle on a dedicated queue.
final class FtpSession: BrowsableSession, @unchecked Sendable {
    static let backendName = "ftp"
    static let logger = Logger.ftpBrowsablePlugin

    let configuration: FtpConnectionConfiguration

    private static let initializationResult = curl_global_init(Int(CURL_GLOBAL_DEFAULT))
    private let queue = DispatchQueue(label: "app.mankai.browse.ftp", qos: .userInitiated)
    private var handle: UnsafeMutableRawPointer?

    init(configuration: FtpConnectionConfiguration) { self.configuration = configuration }

    deinit { if let handle { curl_easy_cleanup(handle) } }

    func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if let handle = self.handle {
                    curl_easy_cleanup(handle)
                    self.handle = nil
                }
                continuation.resume()
            }
        }
    }

    func list(path: String) async throws -> [BrowsableSessionEntry] {
        let url = try configuration.url(path: path, isDirectory: true)
        if configuration.transferProtocol != .sftp {
            do {
                let data = try await transfer(url: url, listCommand: "MLSD")
                return FtpDirectoryListing.parse(data, machineReadable: true)
            } catch let error as FtpTransferError
                where error.code == CURLE_FTP_COULDNT_RETR_FILE
                && ((500...504).contains(error.responseCode) || error.responseCode == 550)
            {
                // Older FTP servers may only implement LIST.
            }
        }
        let data = try await transfer(url: url)
        let entries = FtpDirectoryListing.parse(data, machineReadable: false)
        guard configuration.transferProtocol == .sftp else { return entries }

        var resolved: [BrowsableSessionEntry] = []
        for entry in entries {
            if entry.isDirectory || entry.isRegularFile {
                resolved.append(entry)
            } else if let target = try await resolveSymbolicLink(entry.name, in: path) {
                resolved.append(target)
            }
        }
        return resolved
    }

    private func resolveSymbolicLink(_ name: String, in directory: String) async throws
        -> BrowsableSessionEntry?
    {
        let path = PathUtilities.appending(name, to: directory)
        let directoryURL = try configuration.url(path: path, isDirectory: true)
        if (try? await transfer(url: directoryURL)) != nil {
            return BrowsableSessionEntry(name: name, isDirectory: true, isRegularFile: false)
        }
        try Task.checkCancellation()
        let fileURL = try configuration.url(path: path, isDirectory: false)
        let metadata = try? await transfer(url: fileURL, metadataOnly: true)
        try Task.checkCancellation()
        guard metadata != nil else { return nil }
        return BrowsableSessionEntry(name: name, isDirectory: false, isRegularFile: true)
    }

    func fileIfExists(path: String) async throws -> Data? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let entries = try await list(path: parent)
        if let entry = entries.first(where: { $0.name == name }) {
            return entry.isRegularFile ? try await download(path: path) : nil
        }
        // An FTP LIST response can omit dotfiles, including the share's existing identity.
        guard configuration.transferProtocol != .sftp, name.hasPrefix(".") else { return nil }
        do { return try await download(path: path) } catch let error as FtpTransferError
            where error.code == CURLE_REMOTE_FILE_NOT_FOUND
            || (error.code == CURLE_FTP_COULDNT_RETR_FILE && error.responseCode == 550)
        { return nil }
    }

    func download(path: String) async throws -> Data {
        try await transfer(url: configuration.url(path: path, isDirectory: false))
    }

    func upload(data: Data, path: String) async throws {
        _ = try await transfer(url: configuration.url(path: path, isDirectory: false), upload: data)
    }

    private func transfer(
        url: URL, listCommand: String? = nil, upload: Data? = nil, metadataOnly: Bool = false
    ) async throws -> Data {
        try Task.checkCancellation()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(
                        with: Result {
                            try self.perform(
                                url: url, listCommand: listCommand, upload: upload,
                                metadataOnly: metadataOnly, cancelled: cancelled)
                        })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        try Task.checkCancellation()
        return data
    }

    private func perform(
        url: URL, listCommand: String?, upload: Data?, metadataOnly: Bool,
        cancelled: OSAllocatedUnfairLock<Bool>
    ) throws -> Data {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
        guard Self.initializationResult == CURLE_OK else {
            throw FtpTransferError(code: Self.initializationResult)
        }
        if handle == nil { handle = curl_easy_init() }
        guard let handle else { throw FtpTransferError(code: CURLE_FAILED_INIT) }

        var caFile: String?
        if configuration.transferProtocol.usesTLS {
            guard let path = Bundle.main.path(forResource: "cacert", ofType: "pem") else {
                throw FtpTransferError(code: CURLE_SSL_CACERT_BADFILE)
            }
            caFile = path
        }
        let anonymous = configuration.username.isEmpty
        let username = anonymous ? nil : configuration.username
        let password = anonymous && configuration.password.isEmpty ? nil : configuration.password
        let transfer = FtpTransfer(upload: upload ?? Data(), cancelled: cancelled)
        let context = Unmanaged.passUnretained(transfer).toOpaque()
        var errorBuffer = [CChar](repeating: 0, count: Int(CURL_ERROR_SIZE))
        var responseCode = 0
        let code = MankaiFtpTransfer(
            handle, url.absoluteString, username, password, caFile, listCommand,
            upload.map { curl_off_t($0.count) } ?? -1, metadataOnly ? 1 : 0, context,
            { bytes, size, count, context in
                guard let bytes, let context else { return 0 }
                let transfer = Unmanaged<FtpTransfer>.fromOpaque(context).takeUnretainedValue()
                let length = size * count
                transfer.download.append(
                    UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: length)
                return length
            },
            { bytes, size, count, context in
                guard let bytes, let context else { return 0 }
                let transfer = Unmanaged<FtpTransfer>.fromOpaque(context).takeUnretainedValue()
                let length = min(size * count, transfer.upload.count - transfer.offset)
                _ = transfer.upload.copyBytes(
                    to: UnsafeMutableRawBufferPointer(start: bytes, count: length),
                    from: transfer.offset..<(transfer.offset + length))
                transfer.offset += length
                return length
            },
            { context, _, _, _, _ in
                guard let context else { return 1 }
                let transfer = Unmanaged<FtpTransfer>.fromOpaque(context).takeUnretainedValue()
                return transfer.cancelled.withLock { $0 ? 1 : 0 }
            }, &errorBuffer, &responseCode)
        if cancelled.withLock({ $0 }) { throw CancellationError() }
        guard code == CURLE_OK else {
            let message = errorBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            throw FtpTransferError(code: code, responseCode: responseCode, message: message)
        }
        return transfer.download
    }
}

/// The easy interface calls these callbacks synchronously on the session queue.
private final class FtpTransfer {
    let upload: Data
    let cancelled: OSAllocatedUnfairLock<Bool>
    var offset = 0
    var download = Data()

    init(upload: Data, cancelled: OSAllocatedUnfairLock<Bool>) {
        self.upload = upload
        self.cancelled = cancelled
    }
}

private struct FtpTransferError: LocalizedError {
    let code: CURLcode
    var responseCode = 0
    var message = ""

    var errorDescription: String? {
        message.isEmpty ? String(cString: curl_easy_strerror(code)) : message
    }
}

private enum FtpDirectoryListing {
    // Unix LIST and SFTP long names, plus the DOS format returned by IIS FTP.
    private static let unix = try! NSRegularExpression(
        pattern: #"^([dl-])\S{9}[+@.]?(?:[ \t]+\S+){4}[ \t]+"#
            + #"(?:\S+[ \t]+\d{1,2}|\d{1,2}[ \t]+\S+)[ \t]+[\d:]+[ \t](.+)$"#)
    private static let dos = try! NSRegularExpression(
        pattern: #"^\d{2}-\d{2}-\d{2,4}[ \t]+\d{1,2}:\d{2}(?:[ \t]?[AP]M)?"#
            + #"[ \t]+(<DIR>|\d+)[ \t]+(.+)$"#, options: .caseInsensitive)

    static func parse(_ data: Data, machineReadable: Bool) -> [BrowsableSessionEntry] {
        let listing = String(decoding: data, as: UTF8.self)
        return listing.split(whereSeparator: \.isNewline)
            .compactMap { line in
                let name: String
                let isDirectory: Bool
                var isSymbolicLink = false
                if machineReadable {
                    guard let separator = line.firstIndex(of: " "),
                        let type = line[..<separator].lowercased().split(separator: ";")
                            .first(where: { $0.hasPrefix("type=") }),
                        type == "type=dir" || type == "type=file"
                    else { return nil }
                    name = String(line[line.index(after: separator)...])
                    isDirectory = type == "type=dir"
                } else {
                    let text = String(line)
                    let range = NSRange(text.startIndex..., in: text)
                    guard
                        let match = unix.firstMatch(in: text, range: range)
                            ?? dos.firstMatch(in: text, range: range),
                        let typeRange = Range(match.range(at: 1), in: text),
                        let nameRange = Range(match.range(at: 2), in: text)
                    else { return nil }
                    let type = text[typeRange]
                    let listedName = text[nameRange]
                    isSymbolicLink = type == "l"
                    if isSymbolicLink, let arrow = listedName.range(of: " -> ") {
                        name = String(listedName[..<arrow.lowerBound])
                    } else {
                        name = String(listedName)
                    }
                    isDirectory = type == "d" || type.uppercased() == "<DIR>"
                }
                guard PathUtilities.isValidComponent(name) else { return nil }
                return BrowsableSessionEntry(
                    name: name, isDirectory: isDirectory,
                    isRegularFile: !isDirectory && !isSymbolicLink)
            }
    }
}
