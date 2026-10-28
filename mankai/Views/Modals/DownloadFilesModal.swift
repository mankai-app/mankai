//
//  DownloadFilesModal.swift
//  mankai
//
//  Created by Travis XU on 25/10/2026.
//

import SwiftUI

struct DownloadFilesModal: View {
    private struct FileDownload: Identifiable {
        let id = UUID()
        let file: ParserFile
        var status: DownloadState = .queued
        var progress: Double?
        var savedURL: URL?
        var errorMessage: String?
    }

    private let onShowDownloads: (() -> Void)?
    private let unavailableFileNames: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var downloads: [FileDownload]
    @State private var downloadTask: Task<Void, Never>?

    init(
        files: [ParserFile], unavailableFileNames: [String] = [],
        onShowDownloads: (() -> Void)? = nil
    ) {
        self.onShowDownloads = onShowDownloads
        self.unavailableFileNames = unavailableFileNames

        _downloads = State(initialValue: files.map { FileDownload(file: $0) })
    }

    private var completedCount: Int { downloads.filter { $0.status == .completed }.count }

    var body: some View {
        NavigationStack {
            List {
                if !downloads.isEmpty {
                    Section {
                        ForEach(downloads) { download in fileRow(download) }
                    } footer: {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "downloadFilesLocation"),
                                AppDirBrowsablePlugin.shared.name ?? AppDirBrowsablePlugin.shared.id
                            ))
                    }
                }

                if !unavailableFileNames.isEmpty {
                    Section {
                        ForEach(Array(unavailableFileNames.enumerated()), id: \.offset) { _, name in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name).font(.headline).lineLimit(2)

                                Text("failed").font(.caption).foregroundStyle(.red)

                                Text("downloadFileUnavailable").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if downloadTask == nil, completedCount > 0, let onShowDownloads {
                    Section {
                        Button {
                            onShowDownloads()

                            dismiss()
                        } label: {
                            HStack {
                                Label("openDownloadsFolder", systemImage: "folder")

                                Spacer()

                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.primary).contentShape(Rectangle())
                        }
                    }
                }
            }
            .navigationTitle("downloadFiles").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close") {
                        downloadTask?.cancel()

                        dismiss()
                    }
                }

                if downloadTask == nil, completedCount < downloads.count {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            startDownloads()
                        } label: {
                            if downloads.contains(where: { $0.status == .failed }) {
                                Text("retry")
                            } else {
                                Text("download")
                            }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.hidden)
        .onDisappear { downloadTask?.cancel() }
    }

    private func fileRow(_ download: FileDownload) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(download.savedURL?.lastPathComponent ?? download.file.fileName).font(.headline)
                    .lineLimit(2)

                Text(download.status.label).font(.caption)
                    .foregroundStyle(download.status == .failed ? Color.red : .secondary)

                if download.status == .downloading { ProgressView(value: download.progress ?? 0) }

                if let errorMessage = download.errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if download.status == .completed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private func startDownloads() {
        guard downloadTask == nil else { return }

        let directory = AppDirBrowsablePlugin.shared.url.appendingPathComponent(
            "dowloads", isDirectory: true)

        downloadTask = Task { @MainActor in
            defer { downloadTask = nil }

            for index in downloads.indices where downloads[index].status != .completed {
                guard !Task.isCancelled else { break }

                downloads[index].status = .downloading
                downloads[index].progress = nil
                downloads[index].errorMessage = nil

                do {
                    let file = downloads[index].file

                    let source = try await file.getUrl { value in
                        Task { @MainActor in
                            guard downloads[index].status == .downloading else { return }

                            downloads[index].progress = value
                        }
                    }

                    try Task.checkCancellation()

                    let copyTask = Task.detached(priority: .utility) {
                        let fileManager = FileManager.default

                        try fileManager.createDirectory(
                            at: directory, withIntermediateDirectories: true)

                        let originalName = file.fileName as NSString
                        let fileExtension = originalName.pathExtension

                        let sanitizedName =
                            fileExtension.isEmpty
                            ? FileUtilities.sanitizedStem(file.fileName)
                            : FileUtilities.filename(
                                for: originalName.deletingPathExtension,
                                fileExtension: fileExtension)

                        let proposedURL = directory.appendingPathComponent(
                            sanitizedName, isDirectory: false)

                        let fileName = FileUtilities.uniqueFileName(
                            for: proposedURL,
                            existingNames: Set(
                                try fileManager.contentsOfDirectory(atPath: directory.path)))

                        let destination = directory.appendingPathComponent(
                            fileName, isDirectory: false)

                        let temporaryURL = directory.appendingPathComponent(
                            ".\(UUID().uuidString).download")

                        defer { try? fileManager.removeItem(at: temporaryURL) }

                        try Task.checkCancellation()
                        try fileManager.copyItem(at: source, to: temporaryURL)

                        try Task.checkCancellation()
                        try fileManager.moveItem(at: temporaryURL, to: destination)

                        return destination
                    }

                    downloads[index].savedURL = try await withTaskCancellationHandler {
                        try await copyTask.value
                    } onCancel: {
                        copyTask.cancel()
                    }

                    downloads[index].status = .completed
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        downloads[index].status = .cancelled

                        break
                    }

                    downloads[index].errorMessage = error.localizedDescription
                    downloads[index].status = .failed
                }
            }
        }
    }
}
