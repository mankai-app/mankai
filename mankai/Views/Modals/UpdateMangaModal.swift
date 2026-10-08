//
//  UpdateMangaModal.swift
//  mankai
//
//  Created by Travis XU on 1/7/2025.
//

import PhotosUI
import SwiftUI

struct UpdateMangaModal: View {
    @Environment(\.dismiss) var dismiss

    var plugin: (any Editable)? = nil
    var manga: DetailedManga? = nil

    var body: some View {
        NavigationView {
            UpdateMangaContent(
                plugin: plugin, manga: manga,
                plugins: PluginService.shared.plugins.compactMap { $0 as? any Editable }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) { Text("cancel") }
                }
            }
        }
    }
}

struct UpdateMangaContent: View {
    let plugins: [any Editable]
    let isCreatingManga: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var plugin: String
    @State private var manga: DetailedManga

    @State private var showingAddAuthorAlert = false
    @State private var newAuthorName = ""
    @State private var showingRemoveAuthorsConfirmation = false
    @State private var authorsToRemove: [String] = []
    @State private var showingRemoveGenresConfirmation = false
    @State private var genresToRemove: [Genre] = []
    @State private var showingAddChapterGroupAlert = false
    @State private var newChapterGroup = ""
    @State private var showingRemoveChapterGroupAlert = false
    @State private var chapterGroupIndexToRemove: Int?

    @State private var coverImageData: Data?
    @State private var isCoverChanged = false
    @State private var selectedPhoto: PhotosPickerItem?

    @State private var showingErrorAlert = false
    @State private var errorMessage = ""
    @State private var errorTitle = ""
    @State private var isProcessing = false
    @State private var showingDeleteConfirmation = false

    init(plugin: (any Editable)? = nil, manga: DetailedManga? = nil, plugins: [any Editable]) {
        self.plugins = plugins
        isCreatingManga = manga == nil

        _plugin = State(initialValue: plugin?.id ?? AppDirPlugin.shared.id)
        _manga = State(initialValue: manga ?? DetailedManga())
    }

    private var title: Binding<String> {
        Binding<String>(get: { manga.title ?? "" }, set: { manga.title = $0 })
    }

    private var description: Binding<String> {
        Binding<String>(get: { manga.description ?? "" }, set: { manga.description = $0 })
    }

    private var status: Binding<Status> {
        Binding<Status>(get: { manga.status ?? .onGoing }, set: { manga.status = $0 })
    }

    private func loadCoverImage() {
        guard !isCreatingManga, let coverUrl = manga.cover, !coverUrl.isEmpty,
            let plugin = plugins.first(where: { $0.id == plugin }), plugin.supports(.image)
        else {
            coverImageData = nil
            return
        }

        Task {
            do {
                let imageData = try await plugin.getImage(coverUrl)
                coverImageData = imageData
            } catch { coverImageData = nil }
        }
    }

    private func createChapterGroup() async {
        let trimmedKey = newChapterGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        isProcessing = true

        do {
            guard let selectedPlugin = plugins.first(where: { $0.id == plugin }) else {
                errorTitle = String(localized: "selectedSourceNotFound")
                showingErrorAlert = true
                isProcessing = false
                return
            }

            try await selectedPlugin.upsertChapterGroup(
                EditableChapterGroup(id: nil, title: trimmedKey, mangaId: manga.id))
            if !manga.chapters.contains(where: { $0.title == trimmedKey }) {
                manga.chapters.append(ChapterGroup(title: trimmedKey, chapters: []))
            }
            newChapterGroup = ""
            showingAddChapterGroupAlert = false
            isProcessing = false
        } catch {
            errorTitle = String(localized: "failedToAddChapterGroup")
            errorMessage = error.localizedDescription
            showingErrorAlert = true
            isProcessing = false
        }
    }

    private func requestRemoveAuthors(_ authors: [String]) {
        authorsToRemove = authors
        showingRemoveAuthorsConfirmation = true
    }

    private func requestRemoveGenres(_ genres: [Genre]) {
        genresToRemove = genres
        showingRemoveGenresConfirmation = true
    }

    private func requestRemoveChapterGroup(at index: Int) {
        chapterGroupIndexToRemove = index
        showingRemoveChapterGroupAlert = true
    }

    private func deleteChapterGroup() async {
        guard let chapterGroupIndexToRemove,
            manga.chapters.indices.contains(chapterGroupIndexToRemove)
        else { return }

        isProcessing = true

        do {
            guard let selectedPlugin = plugins.first(where: { $0.id == plugin }) else {
                errorTitle = String(localized: "selectedSourceNotFound")
                showingErrorAlert = true
                isProcessing = false
                return
            }

            guard let id = manga.chapters[chapterGroupIndexToRemove].id else {
                throw MankaiErrorCode.chapterGroupNotFound.makeError()
            }
            try await selectedPlugin.deleteChapterGroup(id: id)

            manga.chapters.remove(at: chapterGroupIndexToRemove)
            self.chapterGroupIndexToRemove = nil
            showingRemoveChapterGroupAlert = false
            isProcessing = false
        } catch {
            errorTitle = String(localized: "failedToRemoveChapterGroup")
            errorMessage = error.localizedDescription
            showingErrorAlert = true
            isProcessing = false
        }
    }

    private func updateManga() async {
        isProcessing = true

        do {
            guard let selectedPlugin = plugins.first(where: { $0.id == plugin }) else {
                errorTitle = String(localized: "selectedSourceNotFound")
                showingErrorAlert = true
                isProcessing = false
                return
            }

            let editableManga = EditableManga(
                id: isCreatingManga ? nil : manga.id, title: manga.title, status: manga.status,
                description: manga.description, authors: manga.authors, genres: manga.genres,
                remarks: manga.remarks)
            let newId = try await selectedPlugin.upsertManga(editableManga)
            manga.id = newId

            if isCoverChanged, let coverData = coverImageData {
                try await selectedPlugin.upsertCover(mangaId: manga.id, image: coverData)
            }

            isProcessing = false
            dismiss()

        } catch {
            errorTitle = String(localized: "failedToUpdateManga")
            errorMessage = error.localizedDescription
            showingErrorAlert = true
            isProcessing = false
        }
    }

    private func deleteManga() async {
        isProcessing = true

        do {
            guard let selectedPlugin = plugins.first(where: { $0.id == plugin }) else {
                errorTitle = String(localized: "selectedSourceNotFound")
                showingErrorAlert = true
                isProcessing = false
                return
            }

            try await selectedPlugin.deleteManga(manga.id)
            isProcessing = false
            dismiss()
        } catch {
            errorTitle = String(localized: "failedToDeleteManga")
            errorMessage = error.localizedDescription
            showingErrorAlert = true
            isProcessing = false
        }
    }

    var body: some View {
        List {
            if isCreatingManga {
                Section {
                    Picker("source", selection: $plugin) {
                        ForEach(plugins, id: \.id) { plugin in
                            Text(plugin.name ?? plugin.id).tag(plugin.id)
                        }
                    }

                } header: {
                    Spacer(minLength: 0)
                }
            }

            Section("cover") {
                HStack(alignment: .center, spacing: 8) {
                    Group {
                        if let coverImageData = coverImageData,
                            let uiImage = UIImage(data: coverImageData)
                        {
                            Image(uiImage: uiImage).resizable().frame(maxWidth: .infinity)
                                .scaledToFill().clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6))
                                .frame(maxWidth: .infinity).aspectRatio(3 / 4, contentMode: .fit)
                                .overlay {
                                    VStack {
                                        Image(systemName: "photo.badge.plus").font(.title)
                                            .foregroundStyle(.secondary)
                                        Text("noCover").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                        }
                    }

                    let isCoverSet = coverImageData != nil
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        HStack {
                            Image(systemName: "photo.badge.plus")
                            Text(isCoverSet ? "changeCover" : "addCover")
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            Section("info") {
                TextField("title", text: title)

                TextField("description", text: description, axis: .vertical).lineLimit(3...6)

                Picker("status", selection: status) {
                    Text("onGoing").tag(Status.onGoing)
                    Text("mangaCompleted").tag(Status.completed)
                }
            }

            Section("authors") {
                if !manga.authors.isEmpty {
                    ForEach(manga.authors, id: \.self) { author in
                        HStack {
                            Text(author)
                            Spacer()

                            Button {
                                requestRemoveAuthors([author])
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundColor(.red)
                            }
                        }
                    }
                    .onDelete { offsets in requestRemoveAuthors(offsets.map { manga.authors[$0] }) }
                }

                Button(action: { showingAddAuthorAlert = true }) {
                    HStack {
                        Text("add")
                        Spacer()
                    }
                }
            }
            .confirmationDialog(
                "remove", isPresented: $showingRemoveAuthorsConfirmation, titleVisibility: .visible
            ) {
                Button("remove", role: .destructive) {
                    manga.authors.removeAll { authorsToRemove.contains($0) }
                    authorsToRemove = []
                }
                Button("cancel", role: .cancel) { authorsToRemove = [] }
            } message: {
                Text("removeAuthorsConfirmation")
            }

            Section("genres") {
                if !manga.genres.isEmpty {
                    ForEach(manga.genres, id: \.self) { genre in
                        HStack {
                            Text(LocalizedStringKey(genre.rawValue))
                            Spacer()

                            Button {
                                requestRemoveGenres([genre])
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundColor(.red)
                            }
                        }
                    }
                    .onDelete { offsets in requestRemoveGenres(offsets.map { manga.genres[$0] }) }
                }

                Menu {
                    ForEach(
                        Genre.allCases.filter { genre in
                            genre != .all && !manga.genres.contains(genre)
                        }, id: \.self
                    ) { genre in
                        Button(action: { manga.genres.append(genre) }) {
                            Text(LocalizedStringKey(genre.rawValue))
                        }
                    }
                } label: {
                    HStack {
                        Text("add")
                        Spacer()
                    }
                }
                .disabled(manga.genres.count >= Genre.allCases.count - 1)
            }
            .confirmationDialog(
                "remove", isPresented: $showingRemoveGenresConfirmation, titleVisibility: .visible
            ) {
                Button("remove", role: .destructive) {
                    manga.genres.removeAll { genresToRemove.contains($0) }
                    genresToRemove = []
                }
                Button("cancel", role: .cancel) { genresToRemove = [] }
            } message: {
                Text("removeGenresConfirmation")
            }

            if !isCreatingManga {
                Section("chapterGroups") {
                    if !manga.chapters.isEmpty {
                        ForEach(Array(manga.chapters.enumerated()), id: \.offset) {
                            chapterGroupIndex, chapterGroup in
                            HStack {
                                Text(LocalizedStringKey(chapterGroup.title))
                                Spacer()

                                Button {
                                    requestRemoveChapterGroup(at: chapterGroupIndex)
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundColor(.red)
                                }
                            }
                        }
                        .onDelete { offsets in
                            guard let index = offsets.first else { return }
                            requestRemoveChapterGroup(at: index)
                        }
                    }

                    Button(action: { showingAddChapterGroupAlert = true }) {
                        HStack {
                            Text("add")
                            Spacer()
                        }
                    }
                }
            }

            if !isCreatingManga {
                Section {
                    Button(
                        "deleteManga", role: .destructive,
                        action: { showingDeleteConfirmation = true })
                } header: {
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear { loadCoverImage() }
        .onChange(of: selectedPhoto) { _, newPhoto in
            Task {
                if let newPhoto = newPhoto {
                    do {
                        if let data = try await newPhoto.loadTransferable(type: Data.self) {
                            coverImageData = data
                            isCoverChanged = true
                        }
                    } catch { Logger.ui.error("Failed to load photo", error: error) }
                }
            }
        }
        .alert("addAuthor", isPresented: $showingAddAuthorAlert) {
            TextField("authorName", text: $newAuthorName)

            Button("add") {
                let trimmedName = newAuthorName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedName.isEmpty && !manga.authors.contains(trimmedName) {
                    manga.authors.append(trimmedName)
                }
                newAuthorName = ""
            }

            Button("cancel", role: .cancel) { newAuthorName = "" }
        } message: {
            Text("enterAuthorName")
        }
        .alert("addChapterGroup", isPresented: $showingAddChapterGroupAlert) {
            TextField("chapterGroup", text: $newChapterGroup)

            Button("add") { Task { await createChapterGroup() } }

            Button("cancel", role: .cancel) { newChapterGroup = "" }
        } message: {
            Text("enterChapterGroup")
        }
        // FIXME: maybe offed
        .confirmationDialog(
            "removeChapterGroup", isPresented: $showingRemoveChapterGroupAlert,
            titleVisibility: .visible
        ) {
            Button("remove", role: .destructive) { Task { await deleteChapterGroup() } }

            Button("cancel", role: .cancel) { chapterGroupIndexToRemove = nil }
        } message: {
            Text("removeChapterGroupConfirmation")
        }
        .alert(errorTitle, isPresented: $showingErrorAlert) {
            Button("ok") {
                errorMessage = ""
                errorTitle = ""
            }
        } message: {
            if !errorMessage.isEmpty { Text(errorMessage) }
        }
        .confirmationDialog(
            "deleteManga", isPresented: $showingDeleteConfirmation, titleVisibility: .visible
        ) {
            Button("delete", role: .destructive) { Task { await deleteManga() } }

            Button("cancel", role: .cancel) {}
        } message: {
            Text("deleteMangaConfirmation")
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(isCreatingManga ? "createManga" : "editManga")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(action: { Task { await updateManga() } }) {
                    if isProcessing {
                        ProgressView()
                    } else {
                        Text(isCreatingManga ? "create" : "done")
                    }
                }
                .disabled(isProcessing)
            }
        }
    }
}
