//
//  DownloadService.swift
//  mankai
//
//  Created by Travis XU on 13/2/2026.
//

import Foundation
import GRDB

// Presentation state. Pause and cancellation belong to the manga download.
enum DownloadState: Equatable {
    case queued, resolving, downloading, paused, waitingForRetry, failed, completed, cancelled

    var label: String {
        switch self { case .queued: return String(localized: "queued") case .resolving:
            return String(localized: "downloadResolving")
            case .downloading: return String(localized: "downloadDownloading")
            case .paused: return String(localized: "downloadPaused")
            case .waitingForRetry: return String(localized: "downloadRetrying")
            case .failed: return String(localized: "failed")
            case .completed: return String(localized: "downloaded")
            case .cancelled: return String(localized: "downloadCancelled")
        }
    }
}

@MainActor final class MangaDownload: Identifiable, ObservableObject {
    var id: String { manga.id }
    @Published fileprivate(set) var manga: DownloadMangaModel
    @Published fileprivate(set) var chapters: [String: ChapterDownload] = [:]
    @Published fileprivate(set) var isChanging = false
    @Published fileprivate(set) var isCancelled = false

    var orderedChapters: [ChapterDownload] {
        chapters.values.sorted { $0.chapter.queueOrder < $1.chapter.queueOrder }
    }

    var hasPendingChapters: Bool {
        !isCancelled && chapters.values.contains { $0.status != .completed }
    }

    var queueOrder: Int64 {
        chapters.values.lazy.filter { self.isCancelled || $0.status != .completed }
            .map { $0.chapter.queueOrder }.min() ?? .max
    }

    var status: DownloadState {
        if isCancelled { return .cancelled }
        guard hasPendingChapters else { return .completed }
        if manga.isPaused { return .paused }

        for state: DownloadState in [.downloading, .resolving, .waitingForRetry, .queued, .failed] {
            if chapters.values.contains(where: { $0.status == state }) { return state }
        }
        return .queued
    }

    func state(for chapter: ChapterDownload) -> DownloadState {
        if isCancelled { return .cancelled }
        if manga.isPaused && chapter.status != .completed { return .paused }
        return chapter.status
    }

    init(manga: DownloadMangaModel) { self.manga = manga }
}

@MainActor final class ChapterDownload: Identifiable, ObservableObject {
    let id: String
    @Published fileprivate(set) var chapter: DownloadChapterModel
    @Published fileprivate(set) var status: DownloadState
    @Published fileprivate(set) var completedImages = 0
    @Published fileprivate(set) var totalImages: Int? = nil
    @Published fileprivate(set) var nextRetryAt: Date? = nil
    @Published fileprivate(set) var errorMessage: String? = nil

    fileprivate var failedAttempts = 0
    fileprivate var retryPageIndex: Int?
    fileprivate var httpStatusCode: Int?
    fileprivate var refreshManifest = false

    var progress: Double {
        guard let count = totalImages, count > 0 else { return 0 }

        return Double(completedImages) / Double(count)
    }

    init(chapter: DownloadChapterModel, images: [DownloadImageModel]) {
        id = chapter.id
        self.chapter = chapter
        status = chapter.completed ? .completed : .queued

        recount(images)
    }

    fileprivate func recount(_ images: [DownloadImageModel]) {
        totalImages = images.isEmpty ? nil : images.count
        completedImages = images.filter(\.completed).count
    }

    fileprivate func resetRetry() {
        failedAttempts = 0
        retryPageIndex = nil
        nextRetryAt = nil
        errorMessage = nil
        httpStatusCode = nil
    }
}

@MainActor final class DownloadService: ObservableObject {
    static let shared = DownloadService()

    @Published private(set) var downloads: [String: MangaDownload] = [:]
    @Published private(set) var isReady = false

    private var runningTasks: [String: Task<Void, Never>] = [:]
    private var restoreTask: Task<Void, Error>?
    private var restoreAttempt = 0
    private var retryWakeTask: Task<Void, Never>?

    private let maximumConcurrentDownloads = 2
    private let maximumAttempts = 3

    private init() {}

    var sessionDownloads: [MangaDownload] {
        downloads.values.filter { $0.status != .completed }.sorted { $0.queueOrder < $1.queueOrder }
    }

    private var db: DatabasePool {
        get throws {
            guard let db = DownloadPlugin.shared.db else {
                throw MankaiErrorCode.downloadDatabaseNotAvailable.makeError()
            }

            return db
        }
    }

    // Enqueueing waits for the same restoration operation used by app startup.
    func start() async throws {
        if isReady { return }

        if restoreTask == nil {
            restoreAttempt += 1
            restoreTask = Task { try await self.restore() }
        }

        let attempt = restoreAttempt

        do { try await restoreTask?.value } catch {
            if attempt == restoreAttempt { restoreTask = nil }
            throw error
        }
    }

    private func restore() async throws {
        let (mangas, chapters, imagesByChapter) = try await db.write { db in
            let mangas = try DownloadMangaModel.fetchAll(db)
            let imagesByChapter = Dictionary(
                grouping: try DownloadImageModel.fetchAll(db), by: \.chapterId)
            let chapters = try DownloadChapterModel.fetchAll(db)
                .map { chapter in
                    var chapter = chapter
                    let images = imagesByChapter[chapter.id] ?? []
                    let completed = !images.isEmpty && images.allSatisfy(\.completed)
                    if chapter.completed != completed {
                        chapter.completed = completed
                        try chapter.update(db)
                    }
                    return chapter
                }

            return (mangas, chapters, imagesByChapter)
        }

        downloads = Dictionary(
            uniqueKeysWithValues: mangas.map { ($0.id, MangaDownload(manga: $0)) })
        for chapter in chapters {
            downloads[chapter.mangaId]?.chapters[chapter.chapterId] = ChapterDownload(
                chapter: chapter, images: imagesByChapter[chapter.id] ?? [])
        }
        isReady = true

        DownloadPlugin.shared.objectWillChange.send()
        scheduleDownloads()
    }

    func chapterState(pluginId: String, mangaId: String, chapterId: String) -> DownloadState? {
        let id = DownloadMangaModel.makeId(pluginId: pluginId, mangaId: mangaId)
        guard let download = downloads[id], let chapter = download.chapters[chapterId] else {
            return nil
        }
        return download.state(for: chapter)
    }

    func queue(plugin: Plugin, manga: DetailedManga, chapters: ChapterGroups) async throws {
        try await start()
        try Task.checkCancellation()

        guard plugin.supportsDownloads else { throw MankaiErrorCode.downloadDisabled.makeError() }

        let pluginId = plugin.id
        let id = DownloadMangaModel.makeId(pluginId: pluginId, mangaId: manga.id)
        let existingDownload = downloads[id]
        let download =
            existingDownload
            ?? MangaDownload(
                manga: DownloadMangaModel(
                    pluginId: pluginId, mangaId: manga.id, id: id, sourceSnapshot: manga,
                    chapters: []))

        guard beginMangaChange(download) else { throw CancellationError() }
        downloads[id] = download
        var didSave = false
        defer {
            if !didSave && existingDownload == nil { downloads.removeValue(forKey: id) }
            endMangaChange(download)
        }

        // Merge metadata and insert only new chapters in one transaction.
        let (model, records, images, didAddChapters) = try await db.write { db in
            let existing = try DownloadMangaModel.fetchOne(db, key: id)
            let previous = existing?.chapters ?? []
            let retained = Set((previous + chapters).flatMap(\.chapters).map(\.id))
            var included: Set<String> = []
            var groups = manga.chapters.compactMap { group -> ChapterGroup? in
                var group = group
                group.chapters = group.chapters.filter {
                    retained.contains($0.id) && included.insert($0.id).inserted
                }

                return group.chapters.isEmpty ? nil : group
            }

            for group in previous + chapters {
                let missing = group.chapters.filter { included.insert($0.id).inserted }

                guard !missing.isEmpty else { continue }

                if let index = groups.firstIndex(where: {
                    if let a = $0.id, let b = group.id { return a == b }

                    return $0.title == group.title
                }) {
                    groups[index].chapters.append(contentsOf: missing)
                } else {
                    groups.append(ChapterGroup(id: group.id, title: group.title, chapters: missing))
                }
            }

            let model = DownloadMangaModel(
                pluginId: pluginId, mangaId: manga.id, id: id, sourceSnapshot: manga,
                chapters: groups, isPaused: existing?.isPaused ?? false)
            try model.save(db)
            var order =
                try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(queueOrder), 0) FROM chapter") ?? 0
            var didAddChapters = false
            var requested: Set<String> = []

            for chapter in chapters.flatMap(\.chapters) {
                guard chapter.locked != true, requested.insert(chapter.id).inserted else {
                    continue
                }

                if try DownloadChapterModel
                    .filter(Column("mangaId") == id && Column("chapterId") == chapter.id)
                    .fetchOne(db) == nil
                {
                    order += 1
                    try DownloadChapterModel(
                        mangaId: id, chapterId: chapter.id, title: chapter.title, queueOrder: order
                    )
                    .insert(db)
                    didAddChapters = true
                }
            }

            let records = try DownloadChapterModel.filter(Column("mangaId") == id).fetchAll(db)
            let images = try DownloadImageModel.filter(Column("mangaId") == id).fetchAll(db)

            return (model, records, images, didAddChapters)
        }
        didSave = true

        let imagesByChapter = Dictionary(grouping: images, by: \.chapterId)
        download.manga = model
        download.isCancelled = false
        download.chapters = Dictionary(
            uniqueKeysWithValues: records.map { record in
                let saved = imagesByChapter[record.id] ?? []

                if let task = download.chapters[record.chapterId], task.id == record.id {
                    task.chapter = record
                    task.recount(saved)
                    return (record.chapterId, task)
                } else {
                    return (record.chapterId, ChapterDownload(chapter: record, images: saved))
                }
            })

        notifyChange(download)
        DownloadPlugin.shared.objectWillChange.send()

        if didAddChapters {
            NotificationService.shared.showInfo(
                String(
                    format: String(localized: "downloadQueuedMessageFormat"),
                    manga.title ?? manga.id))
        }
    }

    func pauseManga(id: String) async throws {
        guard let download = downloads[id], download.hasPendingChapters, !download.manga.isPaused,
            beginMangaChange(download)
        else { return }
        defer { endMangaChange(download) }

        try setPaused(true, for: download)
        await stopDownloads(download)
        for task in download.chapters.values where task.status != .completed {
            try recountProgress(task)
        }
    }

    func cancelManga(id: String) async throws {
        guard let download = downloads[id], download.hasPendingChapters else { return }

        try await removeManga(download, retainingCancelledDownload: true)
    }

    func resumeManga(id: String) async throws {
        guard let download = downloads[id], download.manga.isPaused, download.hasPendingChapters,
            beginMangaChange(download)
        else { return }
        defer { endMangaChange(download) }

        let pending = download.chapters.values.filter { $0.status != .completed }
        for task in pending { try recountProgress(task) }
        try setPaused(false, for: download)
        for task in pending { task.status = .queued }
        notifyChange(download)
    }

    func retryChapter(mangaId: String, chapterId: String) async throws {
        guard let download = downloads[mangaId], !download.isChanging, !download.isCancelled,
            !download.manga.isPaused, let task = download.chapters[chapterId],
            task.status == .failed
        else { return }

        try recountProgress(task)
        task.resetRetry()
        task.refreshManifest = task.totalImages != nil
        task.status = .queued
        notifyChange(download)
        scheduleDownloads()
    }

    func deleteManga(_ manga: DetailedManga) async throws {
        try await start()

        guard let pluginId = manga.meta else {
            throw MankaiErrorCode.pluginDownloadMangaMetaMissing.makeError()
        }

        let id = DownloadMangaModel.makeId(pluginId: pluginId, mangaId: manga.id)
        guard let download = downloads[id] else { return }
        try await removeManga(download, retainingCancelledDownload: false)
    }

    private func removeManga(_ download: MangaDownload, retainingCancelledDownload: Bool)
        async throws
    {
        guard beginMangaChange(download) else { return }
        defer { endMangaChange(download) }

        let wasCancelled = download.isCancelled
        download.isCancelled = true
        notifyChange(download)

        let images: [DownloadImageModel]

        do { images = try DownloadPlugin.shared.deleteManga(download.id) } catch {
            download.isCancelled = wasCancelled
            notifyChange(download)
            throw error
        }

        DownloadPlugin.shared.objectWillChange.send()

        await stopDownloads(download)

        for task in download.chapters.values {
            task.resetRetry()
            task.recount([])
        }
        if !retainingCancelledDownload { downloads.removeValue(forKey: download.id) }
        try await DownloadPlugin.shared.deleteImages(images)
    }

    private func beginMangaChange(_ download: MangaDownload) -> Bool {
        guard !download.isChanging else { return false }

        download.isChanging = true
        objectWillChange.send()
        return true
    }

    private func endMangaChange(_ download: MangaDownload) {
        download.isChanging = false
        objectWillChange.send()
        scheduleDownloads()
    }

    private func stopDownloads(_ download: MangaDownload) async {
        let running = download.chapters.values.compactMap { runningTasks[$0.id] }
        for operation in running { operation.cancel() }
        for operation in running { await operation.value }
    }

    private func setPaused(_ isPaused: Bool, for download: MangaDownload) throws {
        var manga = download.manga
        manga.isPaused = isPaused
        try db.write { try manga.update($0) }
        download.manga = manga
        objectWillChange.send()
    }

    private func notifyChange(_ download: MangaDownload) {
        download.objectWillChange.send()
        objectWillChange.send()
    }

    private func recountProgress(_ task: ChapterDownload) throws {
        let images = try db.read { db in
            try DownloadImageModel.filter(Column("chapterId") == task.id).fetchAll(db)
        }

        task.recount(images)
    }

    private func scheduleDownloads() {
        guard isReady else { return }
        retryWakeTask?.cancel()
        retryWakeTask = nil

        let now = Date()
        let ordered = downloads.values
            .flatMap { download in download.chapters.values.map { (download: download, task: $0) } }
            .sorted { $0.task.chapter.queueOrder < $1.task.chapter.queueOrder }
        let rateLimitedSources = Set(
            ordered.filter { download, task in
                !download.isCancelled && task.status != .completed && task.httpStatusCode == 429
                    && (task.nextRetryAt ?? .distantPast) > now
            }
            .map { $0.download.manga.pluginId })
        var busySources = Set(
            ordered.filter { runningTasks[$0.task.id] != nil }.map { $0.download.manga.pluginId })

        for (download, task) in ordered {
            guard runningTasks.count < maximumConcurrentDownloads else { break }

            guard task.status == .queued || task.status == .waitingForRetry, !download.isChanging,
                !download.isCancelled, !download.manga.isPaused, runningTasks[task.id] == nil,
                !busySources.contains(download.manga.pluginId),
                !rateLimitedSources.contains(download.manga.pluginId),
                (task.nextRetryAt ?? .distantPast) <= now
            else { continue }
            startTask(task, in: download)
            busySources.insert(download.manga.pluginId)
        }

        if let next = ordered.filter({ !$0.download.isCancelled && $0.task.status != .completed })
            .compactMap({ $0.task.nextRetryAt }).filter({ $0 > now }).min()
        {
            retryWakeTask = Task {
                do {
                    try await Task.sleep(
                        for: .seconds(min(86_400, max(0.05, next.timeIntervalSinceNow))))
                    try Task.checkCancellation()
                    self.scheduleDownloads()
                } catch {}
            }
        }
    }

    private func startTask(_ task: ChapterDownload, in download: MangaDownload) {
        task.status = task.totalImages == nil || task.refreshManifest ? .resolving : .downloading
        task.nextRetryAt = nil
        notifyChange(download)

        runningTasks[task.id] = Task {
            defer {
                self.runningTasks.removeValue(forKey: task.id)
                self.scheduleDownloads()
            }

            do { try await self.download(task, in: download) } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.handleFailure(task, in: download, error: error)
            }
        }
    }

    private func checkCurrent(_ task: ChapterDownload, in download: MangaDownload) throws {
        try Task.checkCancellation()

        guard downloads[download.id] === download,
            download.chapters[task.chapter.chapterId] === task, !download.isCancelled,
            !download.manga.isPaused, task.status == .resolving || task.status == .downloading
        else { throw CancellationError() }
    }

    private func beginOperation(_ task: ChapterDownload, pageIndex: Int? = nil) {
        if task.retryPageIndex != pageIndex { task.failedAttempts = 0 }
        task.retryPageIndex = pageIndex
    }

    private func download(_ task: ChapterDownload, in download: MangaDownload) async throws {
        try checkCurrent(task, in: download)

        guard let storedPlugin = PluginService.shared.getPlugin(download.manga.pluginId) else {
            throw MankaiErrorCode.downloadPluginNotFound.makeError()
        }

        let plugin = (storedPlugin as? CacheWrapper)?.plugin ?? storedPlugin

        guard plugin.supportsDownloads else { throw MankaiErrorCode.downloadDisabled.makeError() }

        let manga = download.manga.sourceSnapshot
        let chapter =
            manga.chapters.flatMap(\.chapters).first { $0.id == task.chapter.chapterId }
            ?? Chapter(id: task.chapter.chapterId, title: task.chapter.title)
        let mangaId = download.id
        let taskId = task.id
        let database = try db

        if let coverUrl = download.manga.cover {
            do {
                let cover = try await database.write { db in

                    if let cover =
                        try DownloadImageModel.filter(
                            Column("mangaId") == mangaId && Column("chapterId") == nil
                                && Column("url") == coverUrl
                        )
                        .fetchOne(db)
                    {
                        return cover
                    }

                    let cover = DownloadImageModel(url: coverUrl, mangaId: mangaId)
                    try cover.insert(db)

                    return cover
                }

                if !cover.completed {
                    let data = try await plugin.getImage(coverUrl)
                    try checkCurrent(task, in: download)
                    try await DownloadPlugin.shared.saveImage(cover, data: data)
                    DownloadPlugin.shared.objectWillChange.send()
                }
            } catch {
                try checkCurrent(task, in: download)
                Logger.downloadService.warning("Failed to download cover: \(error)")
            }
        }

        try checkCurrent(task, in: download)
        var images = try await database.read { db in
            try DownloadImageModel.filter(Column("chapterId") == taskId).order(Column("pageIndex"))
                .fetchAll(db)
        }

        if images.isEmpty || task.refreshManifest {
            beginOperation(task)
            let urls = try await plugin.getChapter(manga: manga, chapter: chapter)
            try checkCurrent(task, in: download)

            guard !urls.isEmpty else { throw MankaiErrorCode.downloadEmptyChapter.makeError() }

            let replaced = try await database.write { [images] db -> [DownloadImageModel] in
                // Without stable page IDs, changed locators require a new manifest.
                guard images.map(\.url) != urls else { return [] }
                _ = try DownloadImageModel.filter(Column("chapterId") == taskId).deleteAll(db)

                for (index, url) in urls.enumerated() {
                    try DownloadImageModel(
                        url: url, mangaId: mangaId, chapterId: taskId, pageIndex: index
                    )
                    .insert(db)
                }

                return images
            }

            task.refreshManifest = false
            task.resetRetry()
            task.status = .downloading
            notifyChange(download)

            let directory = DownloadPlugin.shared.downloadDir
            await Task.detached(priority: .utility) {
                for image in replaced {
                    try? FileManager.default.removeItem(
                        at: directory.appendingPathComponent(image.path))
                }
            }
            .value

            try checkCurrent(task, in: download)
            images = try await database.read { db in
                try DownloadImageModel.filter(Column("chapterId") == taskId)
                    .order(Column("pageIndex")).fetchAll(db)
            }
        }

        task.recount(images)

        for image in images {
            try checkCurrent(task, in: download)

            if !image.completed {
                beginOperation(task, pageIndex: image.pageIndex)
                let data = try await plugin.getImage(image.url)
                try checkCurrent(task, in: download)
                try await DownloadPlugin.shared.saveImage(image, data: data)
                try checkCurrent(task, in: download)
                try recountProgress(task)
            }

            if task.retryPageIndex == image.pageIndex { task.resetRetry() }
        }

        try checkCurrent(task, in: download)
        var completed = task.chapter
        completed.completed = true
        try await database.write { [completed] in try completed.update($0) }
        try checkCurrent(task, in: download)
        task.chapter = completed
        task.status = .completed
        notifyChange(download)
        DownloadPlugin.shared.objectWillChange.send()

        if !download.hasPendingChapters {
            NotificationService.shared.showSuccess(
                String(
                    format: String(localized: "downloadCompletedMessageFormat"),
                    download.manga.title ?? download.manga.mangaId))
        }
    }

    private func handleFailure(_ task: ChapterDownload, in download: MangaDownload, error: Error) {
        task.failedAttempts += 1

        do { try recountProgress(task) } catch {
            Logger.downloadService.error("Failed to recount download progress: \(error)")
        }

        let shouldRetry = task.failedAttempts < maximumAttempts && Self.isRetryable(error)
        task.errorMessage = error.localizedDescription
        task.httpStatusCode = Self.httpStatus(error)
        task.nextRetryAt =
            shouldRetry || task.httpStatusCode == 429
            ? Date().addingTimeInterval(Self.retryDelay(error, attempt: task.failedAttempts)) : nil
        task.status = shouldRetry ? .waitingForRetry : .failed
        notifyChange(download)

        if task.status == .failed {
            NotificationService.shared.showError(
                String(
                    format: String(localized: "downloadFailedMessageFormat"),
                    task.chapter.title ?? task.chapter.chapterId, error.localizedDescription))
        }
    }

    private static func httpStatus(_ error: Error) -> Int? {
        let error = error as NSError

        if let status = error.userInfo[MankaiErrorUserInfoKey.httpStatusCode] as? Int {
            return status
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return httpStatus(underlying)
        }

        return nil
    }

    private static func retryDelay(_ error: Error, attempt: Int) -> TimeInterval {
        let base = pow(2, Double(max(1, attempt))) + Double.random(in: 0...1)
        let error = error as NSError

        if let value = error.userInfo[MankaiErrorUserInfoKey.retryAfter] as? String {
            if let seconds = Double(value), seconds.isFinite { return max(base, seconds) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

            if let date = formatter.date(from: value) {
                return max(base, date.timeIntervalSinceNow)
            }
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return max(base, retryDelay(underlying, attempt: attempt))
        }

        return base
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let status = httpStatus(error) {
            return status == 408 || status == 429 || (500...599).contains(status)
        }

        let error = error as NSError

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return isRetryable(underlying)
        }

        return error.domain == NSURLErrorDomain
            && [
                NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
                NSURLErrorNotConnectedToInternet, NSURLErrorResourceUnavailable
            ]
            .contains(error.code)
    }
}
