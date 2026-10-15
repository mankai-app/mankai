//
//  ReadWriteFsPlugin.swift
//  mankai
//
//  Created by Travis XU on 1/7/2025.
//

import CryptoKit
import Foundation
import GRDB
import UIKit

class ReadWriteFsPlugin: ReadFsPlugin, Editable {
    private var _db: DatabasePool?
    override var db: DatabasePool? {
        if let db = _db { return db }
        _db = DbService.shared.openFsDb(_dbPath, readOnly: false)
        return _db
    }

    func closeDatabase() throws {
        try DbService.shared.closeFsDb(_dbPath)
        _db = nil
    }

    convenience init(url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw MankaiErrorCode.pluginFilesystemFailedToAccessFolder.makeError()
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let identity = try Self.resolveIdentity(at: url)
        self.init(url: url, id: identity.id, shouldSync: identity.shouldSync)
    }

    // MARK: - Metadata

    override var tags: [String] { [String(localized: "fs")] }

    // MARK: - Helper Methods

    private static func getImageInfo(from imageData: Data) async -> (
        format: String, width: Int, height: Int
    ) {
        await Task.detached(priority: .utility) {
            let format = NSData(data: imageData).imageFormat.rawValue

            if let uiImage = UIImage(data: imageData) {
                return (format, Int(uiImage.size.width), Int(uiImage.size.height))
            }

            return (format, 0, 0)
        }
        .value
    }

    // MARK: - Methods

    func upsertManga(_ manga: EditableManga) async throws -> String {
        Logger.fsPlugin.debug("Upserting manga: \(manga.id ?? "new")")
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for upsertManga")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        let id = manga.id ?? UUID().uuidString

        try await db.write { db in
            var mangaModel = try FsMangaModel.fetchOne(db, key: id)

            if mangaModel == nil {
                mangaModel = FsMangaModel(
                    id: id, title: manga.title, status: manga.status.map { Int($0.rawValue) },
                    description: manga.description, updatedAt: Date(), authors: manga.authors,
                    genres: manga.genres, latestChapterId: nil)
            } else {
                if let title = manga.title { mangaModel?.title = title }
                if let status = manga.status { mangaModel?.status = Int(status.rawValue) }
                if let description = manga.description { mangaModel?.description = description }
                mangaModel?.authors = manga.authors
                mangaModel?.genres = manga.genres
                mangaModel?.updatedAt = Date()
            }

            try mangaModel?.upsert(db)
        }

        objectWillChange.send()

        return id
    }

    func deleteManga(_ mangaId: String) async throws {
        Logger.fsPlugin.debug("Deleting manga: \(mangaId)")
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for deleteManga")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        _ = try await db.write { db in
            try FsMangaModel.filter(Column("id") == mangaId).deleteAll(db)
        }

        let fileManager = FileManager.default
        let mangaDir = url.appendingPathComponent(mangaId)

        if fileManager.fileExists(atPath: mangaDir.path) {
            try? fileManager.removeItem(at: mangaDir)
        }

        objectWillChange.send()
    }

    func upsertCover(mangaId: String, image: Data) async throws {
        Logger.fsPlugin.debug("Upserting cover for manga: \(mangaId)")
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for upsertCover")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        let fileManager = FileManager.default
        let mangaCoverDir = url.appendingPathComponent(mangaId)

        let imageInfo = await Self.getImageInfo(from: image)
        let coverFileName = "cover.\(imageInfo.format)"
        let coverId = "cover-\(mangaId)"

        if !fileManager.fileExists(atPath: mangaCoverDir.path) {
            try fileManager.createDirectory(at: mangaCoverDir, withIntermediateDirectories: true)
        }

        let coverPath = mangaCoverDir.appendingPathComponent(coverFileName)
        let relativeCoverPath = "\(mangaId)/\(coverFileName)"

        let existingCover = try await db.read { db in try FsImageModel.fetchOne(db, key: coverId) }

        if let existingCover = existingCover {
            let oldCoverPath = url.appendingPathComponent(existingCover.path)
            if fileManager.fileExists(atPath: oldCoverPath.path) {
                try fileManager.removeItem(at: oldCoverPath)
            }
        }

        try image.write(to: coverPath)

        try await db.write { db in
            if let existingCover = existingCover {
                var updatedCover = existingCover

                updatedCover.path = relativeCoverPath
                updatedCover.width = imageInfo.width
                updatedCover.height = imageInfo.height

                try updatedCover.update(db)
            } else {
                let coverImage = FsImageModel(
                    id: coverId, path: relativeCoverPath, width: imageInfo.width,
                    height: imageInfo.height, mangaId: mangaId, chapterId: nil)
                try coverImage.insert(db)
            }
        }

        objectWillChange.send()
    }

    // MARK: - Chapter Group Methods

    func upsertChapterGroup(_ group: EditableChapterGroup) async throws {
        guard let mangaId = group.mangaId, let title = group.title else {
            throw MankaiErrorCode.pluginFilesystemMissingRequiredFields.makeError()
        }

        Logger.fsPlugin.debug("Upserting chapter group: \(title) for manga: \(mangaId)")
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for upsertChapterGroup")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        try await db.write { db in
            let newGroup = FsChapterGroupModel(
                id: group.id.flatMap { Int($0) }, mangaId: mangaId, title: title)
            try newGroup.upsert(db)
        }

        objectWillChange.send()
    }

    func deleteChapterGroup(id: String) async throws {
        Logger.fsPlugin.debug("Deleting chapter group: \(id)")
        guard let db = db, let intId = Int(id) else {
            Logger.fsPlugin.error("Database not available for deleteChapterGroup")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        // Fetch the chapter group and its chapters before deletion
        let (mangaId, chapterIds) = try await db.read { db in
            guard let chapterGroup = try FsChapterGroupModel.fetchOne(db, key: intId) else {
                throw MankaiErrorCode.pluginFilesystemChapterGroupNotFound.makeError()
            }

            let chapters = try FsChapterModel.filter(Column("chapterGroupId") == intId).fetchAll(db)

            return (chapterGroup.mangaId, chapters.compactMap { $0.id })
        }

        // Delete chapter directories from filesystem
        let fileManager = FileManager.default
        for chapterId in chapterIds {
            let chapterDir = url.appendingPathComponent(mangaId).appendingPathComponent("chapters")
                .appendingPathComponent(String(chapterId))

            if fileManager.fileExists(atPath: chapterDir.path) {
                try? fileManager.removeItem(at: chapterDir)
            }
        }

        // Delete the chapter group (cascade deletes chapters)
        _ = try await db.write { db in try FsChapterGroupModel.filter(key: intId).deleteAll(db) }

        objectWillChange.send()
    }

    func getChapters(groupId: String) async throws -> [Chapter] {
        guard let db = db, let intGroupId = Int(groupId) else { return [] }

        return try await db.read { db in
            let chapters = try FsChapterModel.filter(Column("chapterGroupId") == intGroupId)
                .fetchAll(db)

            return chapters.sorted { $0.sequence < $1.sequence }
                .map { Chapter(id: String($0.id ?? 0), title: $0.title, locked: nil) }
        }
    }

    // MARK: - Chapter Methods

    func upsertChapter(_ chapter: EditableChapter) async throws {
        guard let title = chapter.title, let chapterGroupId = chapter.chapterGroupId else {
            throw MankaiErrorCode.pluginFilesystemMissingRequiredFields.makeError()
        }

        let intId = chapter.id.flatMap { Int($0) }
        let intChapterGroupId = Int(chapterGroupId)
        Logger.fsPlugin.debug(
            "Upserting chapter: \(title) (id: \(intId ?? -1), groupId: \(chapterGroupId))")
        guard let db = db, let intChapterGroupId = intChapterGroupId else {
            Logger.fsPlugin.error("Database not available for upsertChapter")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        try await db.write { db in
            let existingChapter = try FsChapterModel.fetchOne(db, key: intId)
            let existingChapterId = existingChapter?.id
            let sequence: Int
            if intId == nil || existingChapter == nil {
                let maxSequence =
                    try
                    (FsChapterModel.filter(Column("chapterGroupId") == intChapterGroupId)
                    .select(max(Column("sequence"))).asRequest(of: Int?.self).fetchOne(db) ?? nil)
                    ?? -1
                sequence = maxSequence + 1
            } else {
                sequence = existingChapter!.sequence
            }

            let chapterModel = try FsChapterModel(
                id: existingChapterId, title: title, sequence: sequence,
                chapterGroupId: intChapterGroupId
            )
            .upsertAndFetch(db)

            if existingChapterId == nil, let newChapterId = chapterModel.id {
                if let chapterGroup = try FsChapterGroupModel.fetchOne(db, key: intChapterGroupId) {
                    if var manga = try FsMangaModel.fetchOne(db, key: chapterGroup.mangaId) {
                        manga.latestChapterId = newChapterId
                        try manga.update(db)
                    }
                }
            }
        }

        objectWillChange.send()
    }

    func deleteChapter(id: String) async throws {
        Logger.fsPlugin.debug("Deleting chapter: \(id)")
        guard let db = db, let intId = Int(id) else {
            Logger.fsPlugin.error("Database not available for deleteChapter")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        // Look up mangaId from chapter -> chapterGroup
        let mangaId: String? = try await db.read { db in
            guard let chapter = try FsChapterModel.fetchOne(db, key: intId) else { return nil }
            let group = try FsChapterGroupModel.fetchOne(db, key: chapter.chapterGroupId)
            return group?.mangaId
        }

        _ = try await db.write { db in try FsChapterModel.filter(key: intId).deleteAll(db) }

        // Delete chapter directory if it exists
        if let mangaId = mangaId {
            let fileManager = FileManager.default
            let chapterDir = url.appendingPathComponent(mangaId).appendingPathComponent("chapters")
                .appendingPathComponent(id)

            if fileManager.fileExists(atPath: chapterDir.path) {
                try? fileManager.removeItem(at: chapterDir)
            }
        }

        objectWillChange.send()
    }

    func arrangeChapterOrder(ids: [String]) async throws {
        Logger.fsPlugin.debug("Arranging chapter order for chapter group")
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for arrangeChapterOrder")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        let intIds = ids.compactMap { Int($0) }
        try await db.write { db in
            // Update sequence for each chapter based on its position in the ids array
            for (index, id) in intIds.enumerated() {
                if var chapterModel = try FsChapterModel.fetchOne(db, key: id) {
                    chapterModel.sequence = index
                    try chapterModel.update(db)
                }
            }
        }

        objectWillChange.send()
    }

    func addImages(chapterId: String, images: [Data]) async throws {
        Logger.fsPlugin.debug("Adding \(images.count) images to chapter: \(chapterId)")
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for addImages")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        // Look up mangaId from chapter -> chapterGroup
        let mangaId: String = try await db.read { db in
            guard let chapterIdInt = Int(chapterId),
                let chapter = try FsChapterModel.fetchOne(db, key: chapterIdInt),
                let group = try FsChapterGroupModel.fetchOne(db, key: chapter.chapterGroupId)
            else { throw MankaiErrorCode.pluginFilesystemChapterNotFound.makeError() }
            return group.mangaId
        }

        let fileManager = FileManager.default
        let chapterDir = url.appendingPathComponent(mangaId).appendingPathComponent("chapters")
            .appendingPathComponent(chapterId)

        if !fileManager.fileExists(atPath: chapterDir.path) {
            try fileManager.createDirectory(at: chapterDir, withIntermediateDirectories: true)
        }

        var writtenFiles: [URL] = []
        var imagePaths: [(String, String, Int, Int)] = []

        do {
            for imageData in images {
                let imageInfo = await Self.getImageInfo(from: imageData)
                let imageId = UUID().uuidString
                let imageFileName = "\(imageId).\(imageInfo.format)"

                let imagePath = chapterDir.appendingPathComponent(imageFileName)
                let relativeImagePath = "\(mangaId)/chapters/\(chapterId)/\(imageFileName)"

                try imageData.write(to: imagePath)
                writtenFiles.append(imagePath)
                imagePaths.append((relativeImagePath, imageId, imageInfo.width, imageInfo.height))
            }

            let pathsToInsert = imagePaths
            try await db.write { db in
                // Get the current max sequence for this chapter
                if let chapterIdInt = Int(chapterId) {
                    let maxSequence =
                        try
                        (FsImageModel.filter(Column("chapterId") == chapterIdInt)
                        .select(max(Column("sequence"))).asRequest(of: Int?.self).fetchOne(db)
                        ?? nil) ?? -1

                    var currentSequence = maxSequence + 1

                    for (relativeImagePath, imageId, width, height) in pathsToInsert {
                        let imageModel = FsImageModel(
                            id: imageId, path: relativeImagePath, width: width, height: height,
                            mangaId: nil, chapterId: chapterIdInt, sequence: currentSequence)
                        try imageModel.insert(db)
                        currentSequence += 1
                    }
                }
            }
        } catch {
            for fileURL in writtenFiles { try? fileManager.removeItem(at: fileURL) }
            throw error
        }

        objectWillChange.send()
    }

    func deleteImages(ids: [String]) async throws {
        Logger.fsPlugin.debug("Deleting \(ids.count) images")
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for deleteImages")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        let fileManager = FileManager.default

        let imageModels = try await db.read { db in try FsImageModel.filter(keys: ids).fetchAll(db)
        }

        for imageModel in imageModels {
            let imagePath = url.appendingPathComponent(imageModel.path)
            if fileManager.fileExists(atPath: imagePath.path) {
                try? fileManager.removeItem(at: imagePath)
            }
        }

        _ = try await db.write { db in try FsImageModel.filter(keys: ids).deleteAll(db) }

        objectWillChange.send()
    }

    func arrangeImageOrder(ids: [String]) async throws {
        Logger.fsPlugin.debug("Arranging image order for chapter")
        guard let db = db else {
            Logger.fsPlugin.error("Database not available for arrangeImageOrder")
            throw MankaiErrorCode.pluginFilesystemDatabaseNotAvailable.makeError()
        }

        try await db.write { db in
            // Update sequence for each image based on its position in the ids array
            for (index, id) in ids.enumerated() {
                if var imageModel = try FsImageModel.fetchOne(db, key: id) {
                    imageModel.sequence = index
                    try imageModel.update(db)
                }
            }
        }

        objectWillChange.send()
    }
}
