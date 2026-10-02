//
//  ZipArchiveReader.swift
//  mankai
//
//  Created by Travis XU on 2/10/2026.
//

import Foundation
import ZIPFoundation

/// Shared ZIP loading, caching, and serialized reads for archive-based parsers.
@MainActor final class ZipArchiveReader {
    private let logger: Logger

    init(logger: Logger) { self.logger = logger }

    /// Couples each ZIPFoundation archive to the lock that serializes its reads.
    /// Retaining this wrapper for an operation keeps an evicted archive alive until that operation has finished.
    nonisolated private final class CachedArchive: @unchecked Sendable {
        let archive: Archive
        let readLock = NSLock()

        init(archive: Archive) { self.archive = archive }
    }

    private var cachedArchiveKey: String?
    private var cachedArchive: CachedArchive?
    private let cacheLock = NSLock()
    private let archiveLoadRegistry = AsyncLoadRegistry<CachedArchive>()

    private func cachedArchive(for cacheKey: String) -> CachedArchive? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard cachedArchiveKey == cacheKey else { return nil }
        return cachedArchive
    }

    /// Stores `archive` unless another request populated the same key while its content was loading.
    /// Opening a different key evicts the previous archive.
    private func storeArchive(_ archive: CachedArchive, for cacheKey: String) -> CachedArchive {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if cachedArchiveKey == cacheKey, let cachedArchive { return cachedArchive }

        cachedArchiveKey = cacheKey
        cachedArchive = archive
        return archive
    }

    /// Returns the `Archive` for `file`, loading its backend-neutral content only when the reader cache does not already contain `file.cacheKey`.
    private func archive(for file: ParserFile) async throws -> CachedArchive {
        if let cached = cachedArchive(for: file.cacheKey) {
            logger.debug("Reusing cached archive: \(file.cacheKey)")
            return cached
        }

        return try await archiveLoadRegistry.value(for: file.cacheKey) { @MainActor [self, file] in
            if let cached = cachedArchive(for: file.cacheKey) {
                logger.debug("Reusing cached archive: \(file.cacheKey)")
                return cached
            }

            logger.debug("Loading archive content: \(file.cacheKey)")
            let data = try await file.getContent()
            let loadedArchive =
                try await Task.detached(priority: .utility) {
                    let archive = try Archive(data: data, accessMode: .read)
                    return CachedArchive(archive: archive)
                }
                .value
            return storeArchive(loadedArchive, for: file.cacheKey)
        }
    }

    /// Keeping the lock operation in a synchronous helper avoids suspending while an `NSLock` is held.
    nonisolated private static func performRead<T>(
        cachedArchive: CachedArchive, body: @Sendable (Archive) throws -> T
    ) rethrows -> T {
        cachedArchive.readLock.lock()
        defer { cachedArchive.readLock.unlock() }
        return try body(cachedArchive.archive)
    }

    /// Resolves the (cached) `Archive` for `file` and runs `body` under its read lock.
    func withReadLock<T: Sendable>(
        for file: ParserFile, body: @escaping @Sendable (Archive) throws -> T
    ) async throws -> T {
        logger.debug("Acquiring read lock for: \(file.cacheKey)")
        let cachedArchive = try await archive(for: file)
        return
            try await Task.detached(priority: .utility) {
                try Self.performRead(cachedArchive: cachedArchive, body: body)
            }
            .value
    }

    /// Reads a regular file entry from the cached archive under its read lock.
    func readEntry(path: String, file: ParserFile) async throws -> Data {
        logger.debug("Reading archive entry: \(path)")

        return try await withReadLock(for: file) { [logger] archive in
            guard let entry = archive[path], entry.type == .file else {
                logger.error("Entry not found in archive: \(path)")
                throw MankaiErrorCode.browseArchiveEntryNotFound.makeError()
            }

            return try Self.entryData(archive: archive, entry: entry)
        }
    }

    /// Extracts entry data. Call only while holding the archive read lock.
    nonisolated static func entryData(archive: Archive, entry: Entry) throws -> Data {
        var data = Data()
        _ = try archive.extract(entry, consumer: { chunk in data.append(chunk) })
        return data
    }
}
