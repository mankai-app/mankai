//
//  UpdateChaptersModal.swift
//  mankai
//
//  Created by Travis XU on 3/7/2025.
//

import SwiftUI

struct UpdateChaptersModal: View {
    let plugin: any Editable
    let manga: DetailedManga
    let chapterGroupIndex: Int
    var isRootOfSheet: Bool

    private let chapterGroupTitle: String?

    @State private var chapters: [Chapter] = []
    @State private var showingAddAlert = false
    @State private var newChapterName = ""
    @State private var showingErrorAlert = false
    @State private var errorMessage = ""
    @State private var showingDeleteConfirmation = false
    @State private var chapterIdsToDelete: [String] = []

    @State private var chapterGroupId: String? = nil

    @Environment(\.dismiss) private var dismiss

    init(
        plugin: any Editable, manga: DetailedManga, chapterGroupIndex: Int,
        isRootOfSheet: Bool = false
    ) {
        self.plugin = plugin
        self.manga = manga
        self.chapterGroupIndex = chapterGroupIndex
        self.isRootOfSheet = isRootOfSheet
        chapterGroupTitle =
            manga.chapters.indices.contains(chapterGroupIndex)
            ? manga.chapters[chapterGroupIndex].title : nil
    }

    private func fetchChapters() {
        guard let groupId = chapterGroupId else { return }
        Task {
            do {
                let fetchedChapters = try await plugin.getChapters(groupId: groupId)
                chapters = fetchedChapters
            } catch {
                errorMessage = error.localizedDescription
                showingErrorAlert = true
            }
        }
    }

    private func moveChapter(from source: IndexSet, to destination: Int) {
        chapters.move(fromOffsets: source, toOffset: destination)

        let currentChapters = chapters
        Task {
            do {
                let ids = currentChapters.map { $0.id }
                try await plugin.arrangeChapterOrder(ids: ids)

                fetchChapters()
            } catch {
                errorMessage = error.localizedDescription
                showingErrorAlert = true
            }
        }
    }

    private func renameChapter(for chapterId: String, to newTitle: String) {
        Task {
            do {
                guard let groupId = chapterGroupId else {
                    throw MankaiErrorCode.chapterGroupNotFound.makeError()
                }

                try await plugin.upsertChapter(
                    EditableChapter(id: chapterId, title: newTitle, chapterGroupId: groupId))

                fetchChapters()
            } catch {
                errorMessage = error.localizedDescription
                showingErrorAlert = true
            }
        }
    }

    @ViewBuilder private var chapterList: some View {
        List {
            Section {
                Button("add") { showingAddAlert = true }.padding(.horizontal, 20)

                ForEach(chapters, id: \.id) { chapter in
                    NavigationLink(destination: {
                        UpdateChapterModal(
                            plugin: plugin, manga: manga, chapter: chapter,
                            onRename: { id, title in renameChapter(for: id, to: title) })
                    }) {
                        Text((chapter.title ?? chapter.id).localizedChapterLabel)
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 20)
                }
                .onMove(perform: moveChapter)
                .onDelete { offsets in
                    chapterIdsToDelete = offsets.map { chapters[$0].id }
                    showingDeleteConfirmation = true
                }
            } header: {
                Text("editChaptersInstructions").font(.caption).textCase(.none)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.bottom)
            }
            .listRowInsets(EdgeInsets())
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    var body: some View {
        NavigationView {
            if isRootOfSheet {
                chapterList.navigationTitleWithSubtitle(
                    title: Text("editChapters"),
                    subtitle: Text(
                        LocalizedStringKey((chapterGroupTitle ?? "").localizedChapterLabel))
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("close") { dismiss() } }
                }
            } else {
                chapterList
            }
        }
        .alert("addChapter", isPresented: $showingAddAlert) {
            TextField("chapterTitle", text: $newChapterName)
            Button("add") {
                let trimmedName = newChapterName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedName.isEmpty {
                    Task {
                        do {
                            guard let groupId = chapterGroupId else {
                                throw MankaiErrorCode.chapterGroupNotFound.makeError()
                            }

                            try await plugin.upsertChapter(
                                EditableChapter(
                                    id: nil, title: trimmedName, chapterGroupId: groupId))

                            fetchChapters()
                        } catch {
                            errorMessage = error.localizedDescription
                            showingErrorAlert = true
                        }
                    }
                }
                newChapterName = ""
            }
            Button("cancel", role: .cancel) { newChapterName = "" }
        } message: {
            Text("enterChapterTitle")
        }
        .alert("failedToEditChapters", isPresented: $showingErrorAlert) {
            Button("ok") {}
        } message: {
            Text(errorMessage)
        }
        .confirmationDialog(
            "delete", isPresented: $showingDeleteConfirmation, titleVisibility: .visible
        ) {
            Button("delete", role: .destructive) {
                let idsToDelete = chapterIdsToDelete
                chapterIdsToDelete = []
                chapters.removeAll { idsToDelete.contains($0.id) }
                Task {
                    do {
                        for id in idsToDelete { try await plugin.deleteChapter(id: id) }
                        fetchChapters()
                    } catch {
                        errorMessage = error.localizedDescription
                        showingErrorAlert = true
                    }
                }
            }
            Button("cancel", role: .cancel) { chapterIdsToDelete = [] }
        } message: {
            Text("deleteChaptersConfirmation")
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitleWithSubtitle(
            title: Text("editChapters"),
            subtitle: Text(LocalizedStringKey((chapterGroupTitle ?? "").localizedChapterLabel))
        )
        .task {
            do {
                guard chapterGroupTitle != nil else {
                    dismiss()
                    return
                }

                guard let groupId = manga.chapters[chapterGroupIndex].id else {
                    throw MankaiErrorCode.chapterGroupNotFound.makeError()
                }
                self.chapterGroupId = groupId
                fetchChapters()
            } catch {
                errorMessage = error.localizedDescription
                showingErrorAlert = true
            }
        }
    }
}
