//
//  AddFilesModal.swift
//  mankai
//
//  Created by Travis XU on 4/8/2026.
//

import SwiftSMB
import SwiftUI
import UniformTypeIdentifiers

struct AddFilesModal: View {
    @ObservedObject private var browseService = BrowseService.shared
    @Environment(\.dismiss) private var dismiss

    enum ShareType: String, CaseIterable, Identifiable {
        case filesystem
        case smb
        case sftp
        case nfs
        case webdav
        case opds

        var id: String { rawValue }

        var localizedName: String {
            switch self { case .filesystem: String(localized: "fs") case .smb:
                String(localized: "smb")
                case .sftp: String(localized: "sftp")
                case .nfs: String(localized: "nfs")
                case .webdav: String(localized: "webdav")
                case .opds: String(localized: "opds")
            }
        }

        var color: Color {
            switch self { case .filesystem: .blue case .smb: .orange case .sftp: .green case .nfs:
                .purple
                case .webdav: .teal
                case .opds: .red
            }
        }

        @ViewBuilder var icon: some View {
            switch self { case .filesystem: Image(systemName: "folder.fill") case .smb:
                LabeledFolderIcon(label: "SMB", color: color)
                case .sftp: LabeledFolderIcon(label: "SSH", color: color)
                case .nfs: LabeledFolderIcon(label: "NFS", color: color)
                case .webdav: LabeledFolderIcon(label: "DAV", color: color)
                case .opds: Image(systemName: "books.vertical.fill")
            }
        }
    }

    @State private var name = ""

    // Fs State
    @State private var selectedFolder: URL?
    @State private var showingFileImporter = false

    // SMB state
    @State private var host = ""
    @State private var port = "445"
    @State private var username = ""
    @State private var password = ""
    @State private var shares: [SMB.Share] = []
    @State private var selectedShare: SMB.Share?
    @State private var showingShareSelection = false

    // SFTP state
    @State private var sftpHost = ""
    @State private var sftpPort = "22"
    @State private var sftpUsername = ""
    @State private var sftpPassword = ""

    // NFS state
    @State private var nfsHost = ""
    @State private var exports: [String] = []
    @State private var selectedExport: String?
    @State private var showingExportSelection = false

    // WebDAV state
    @State private var webDavServerURL = ""
    @State private var webDavUsername = ""
    @State private var webDavPassword = ""

    // OPDS state
    @State private var opdsCatalogURL = ""
    @State private var opdsUsername = ""
    @State private var opdsPassword = ""

    @State private var isLoadingShares = false
    @State private var isLoadingExports = false
    @State private var isAdding = false
    @State private var errorTitle: LocalizedStringKey = "failedToAddFiles"
    @State private var errorMessage: String?
    @State private var duplicateShare: BrowsablePlugin?

    private var isProcessing: Bool { isLoadingShares || isLoadingExports || isAdding }

    private func canContinue(_ type: ShareType) -> Bool {
        guard !isProcessing else { return false }

        switch type { case .filesystem: return selectedFolder != nil case .smb:
            return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .sftp:
                return !sftpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !sftpPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !sftpUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .nfs: return !nfsHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .webdav:
                return !webDavServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .opds:
                return !opdsCatalogURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("localShares") { shareTypeLink(.filesystem) }

                Section("remoteShares") {
                    ForEach([ShareType.smb, .sftp, .nfs, .webdav]) { type in shareTypeLink(type) }
                }

                Section("catalogs") { shareTypeLink(.opds) }
            }
            .navigationTitle("addFiles").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }.disabled(isProcessing)
                }
            }
        }
        .alert(errorTitle, isPresented: errorIsPresented) {
            Button("ok", role: .cancel) { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
        .alert("duplicateShareTitle", isPresented: duplicateShareIsPresented) {
            Button("overwrite", role: .destructive) { resolveDuplicateShare(with: .overwrite) }
            Button("addAsLocalShare") { resolveDuplicateShare(with: .makeLocal) }
            Button("cancel", role: .cancel) { duplicateShare = nil }
        } message: {
            if let duplicateShare {
                Text(
                    String(
                        format: String(localized: "duplicateShareIdOptionsMessageFormat"),
                        locale: .current, duplicateShare.id))
            }
        }
    }

    private func shareTypeLink(_ type: ShareType) -> some View {
        NavigationLink {
            configuration(for: type)
        } label: {
            Label {
                Text(type.localizedName)
            } icon: {
                type.icon
            }
            .labelStyle(ColorfulIconLabelStyle(color: type.color))
        }
    }

    private func configuration(for type: ShareType) -> some View {
        Form {
            Section {
                TextField("default", text: $name).disabled(isProcessing)
            } header: {
                Text("displayName")
            } footer: {
                switch type { case .opds: Text("opdsShareIdSyncHint") default:
                    Text("shareIdSyncHint")
                }
            }

            switch type { case .filesystem: filesystemConfiguration case .smb: smbConfiguration
                case .sftp: sftpConfiguration
                case .nfs: nfsConfiguration
                case .webdav: webDavConfiguration
                case .opds: opdsConfiguration
            }
        }
        .navigationTitle(type.localizedName).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isProcessing)
        .toolbar { ToolbarItem(placement: .confirmationAction) { primaryAction(for: type) } }
        .fileImporter(
            isPresented: $showingFileImporter, allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result { case .success(let urls): selectedFolder = urls.first
                case .failure(let error): presentError(error)
            }
        }
        .navigationDestination(isPresented: $showingShareSelection) { shareSelection }
        .navigationDestination(isPresented: $showingExportSelection) { exportSelection }
    }

    private var filesystemConfiguration: some View {
        Section("filesystemSettings") {
            Button {
                showingFileImporter = true
            } label: {
                HStack {
                    Text("selectFolder")
                    Spacer()
                    Text(selectedFolder?.lastPathComponent ?? String(localized: "none"))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .disabled(isProcessing)
        }
    }

    private var smbConfiguration: some View {
        Section {
            TextField("host", text: $host).textInputAutocapitalization(.never)
                .autocorrectionDisabled().disabled(isProcessing)

            TextField("port", text: $port).keyboardType(.numberPad).disabled(isProcessing)

            TextField("username", text: $username).textInputAutocapitalization(.never)
                .autocorrectionDisabled().textContentType(.username).disabled(isProcessing)

            SecureField("password", text: $password).textContentType(.password)
                .disabled(isProcessing)
        } header: {
            Text("smbSettings")
        } footer: {
            Text("smbSettingsFooter")
        }
    }

    private var nfsConfiguration: some View {
        Section("nfsSettings") {
            TextField("host", text: $nfsHost).textInputAutocapitalization(.never)
                .autocorrectionDisabled().disabled(isProcessing)
        }
    }

    private var sftpConfiguration: some View {
        Section {
            TextField("host", text: $sftpHost).textInputAutocapitalization(.never)
                .autocorrectionDisabled().disabled(isProcessing)

            TextField("port", text: $sftpPort).keyboardType(.numberPad).disabled(isProcessing)

            TextField("username", text: $sftpUsername).textInputAutocapitalization(.never)
                .autocorrectionDisabled().textContentType(.username).disabled(isProcessing)

            SecureField("password", text: $sftpPassword).textContentType(.password)
                .disabled(isProcessing)
        } header: {
            Text("sftpSettings")
        } footer: {
            Text("sftpSettingsFooter")
        }
    }

    private var webDavConfiguration: some View {
        Section {
            TextField("serverUrl", text: $webDavServerURL).keyboardType(.URL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.URL)
                .disabled(isProcessing)

            TextField("username", text: $webDavUsername).textInputAutocapitalization(.never)
                .autocorrectionDisabled().textContentType(.username).disabled(isProcessing)

            SecureField("password", text: $webDavPassword).textContentType(.password)
                .disabled(isProcessing)
        } header: {
            Text("webdavSettings")
        } footer: {
            Text("webdavSettingsFooter")
        }
    }

    private var opdsConfiguration: some View {
        Section {
            TextField("catalogUrl", text: $opdsCatalogURL).keyboardType(.URL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.URL)
                .disabled(isProcessing)

            TextField("username", text: $opdsUsername).textInputAutocapitalization(.never)
                .autocorrectionDisabled().textContentType(.username).disabled(isProcessing)

            SecureField("password", text: $opdsPassword).textContentType(.password)
                .disabled(isProcessing)
        } header: {
            Text("opdsSettings")
        } footer: {
            Text("opdsSettingsFooter")
        }
    }

    private var shareSelection: some View {
        List {
            if shares.isEmpty {
                ContentUnavailableView(
                    "noSmbShares", systemImage: "externaldrive.badge.xmark",
                    description: Text("noSmbSharesDescription"))
            } else {
                Section {
                    ForEach(shares, id: \.name) { share in
                        Button {
                            selectedShare = share
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Label(share.name, systemImage: "externaldrive.fill")
                                    if let remark = share.remark, !remark.isEmpty {
                                        Text(remark).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                if selectedShare == share {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Spacer(minLength: 0)
                }
            }
        }
        .navigationTitle("selectShare").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isAdding)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    addSmbShare()
                } label: {
                    if isAdding { ProgressView() } else { Text("add") }
                }
                .disabled(selectedShare == nil || isProcessing)
            }
        }
    }

    private var exportSelection: some View {
        List {
            if exports.isEmpty {
                ContentUnavailableView(
                    "noNfsExports", systemImage: "externaldrive.badge.xmark",
                    description: Text("noNfsExportsDescription"))
            } else {
                Section {
                    ForEach(exports, id: \.self) { export in
                        Button {
                            selectedExport = export
                        } label: {
                            HStack {
                                Label(export, systemImage: "externaldrive.fill")
                                Spacer()
                                if selectedExport == export {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Spacer(minLength: 0)
                }
            }
        }
        .navigationTitle("selectExport").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isAdding)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    addNfsShare()
                } label: {
                    if isAdding { ProgressView() } else { Text("add") }
                }
                .disabled(selectedExport == nil || isProcessing)
            }
        }
    }

    @ViewBuilder private func primaryAction(for type: ShareType) -> some View {
        switch type { case .filesystem:
            Button {
                addFilesystemShare()
            } label: {
                if isAdding { ProgressView() } else { Text("add") }
            }
            .disabled(!canContinue(type))
            case .smb:
                Button {
                    discoverShares()
                } label: {
                    if isLoadingShares || isAdding { ProgressView() } else { Text("selectShare") }
                }
                .disabled(!canContinue(type))
            case .sftp:
                Button {
                    addSftpShare()
                } label: {
                    if isAdding { ProgressView() } else { Text("add") }
                }
                .disabled(!canContinue(type))
            case .nfs:
                Button {
                    discoverExports()
                } label: {
                    if isLoadingExports || isAdding { ProgressView() } else { Text("selectExport") }
                }
                .disabled(!canContinue(type))
            case .webdav:
                Button {
                    addWebDavShare()
                } label: {
                    if isAdding { ProgressView() } else { Text("add") }
                }
                .disabled(!canContinue(type))
            case .opds:
                Button {
                    addOpdsShare()
                } label: {
                    if isAdding { ProgressView() } else { Text("add") }
                }
                .disabled(!canContinue(type))
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func discoverShares() {
        guard let portValue = parsedPort else {
            presentError(
                MankaiErrorCode.browseSmbInvalidConnectionConfiguration.makeError(),
                title: "failedToDiscoverSmbShares")
            return
        }

        isLoadingShares = true
        Task { @MainActor in
            defer { isLoadingShares = false }

            do {
                let discoveredShares = try await SmbSession.discoverShares(
                    host: host, port: portValue, username: username, password: password)

                shares = discoveredShares
                if discoveredShares.count == 1 {
                    selectedShare = discoveredShares[0]
                    addSmbShare()
                    return
                }

                selectedShare = nil
                showingShareSelection = true
            } catch { presentError(error, title: "failedToDiscoverSmbShares") }
        }
    }

    private func discoverExports() {
        isLoadingExports = true
        Task { @MainActor in
            defer { isLoadingExports = false }

            do {
                let discoveredExports = try await NfsSession.discoverExports(host: nfsHost)
                exports = discoveredExports
                if discoveredExports.count == 1 {
                    selectedExport = discoveredExports[0]
                    addNfsShare()
                    return
                }

                selectedExport = nil
                showingExportSelection = true
            } catch { presentError(error, title: "failedToDiscoverNfsExports") }
        }
    }

    private func addFilesystemShare() {
        guard let selectedFolder else { return }

        isAdding = true
        Task { @MainActor in
            defer { isAdding = false }

            do {
                let share = try FsBrowsablePlugin(url: selectedFolder, name: name)
                addShare(share)
            } catch { presentError(error) }
        }
    }

    private func addSmbShare() {
        guard let selectedShare, let portValue = parsedPort else { return }

        isAdding = true
        Task { @MainActor in
            defer { isAdding = false }

            do {
                let configuration = try SmbConnectionConfiguration(
                    host: host, port: portValue, share: selectedShare.name, username: username,
                    password: password)
                let session = SmbSession(configuration: configuration)
                let share = try await SmbBrowsablePlugin(session: session, name: name)
                addShare(share)
            } catch { presentError(error) }
        }
    }

    private func addNfsShare() {
        guard let selectedExport else { return }

        isAdding = true
        Task { @MainActor in
            defer { isAdding = false }

            do {
                let configuration = try NfsConnectionConfiguration(
                    host: nfsHost, export: selectedExport)
                let session = NfsSession(configuration: configuration)
                let share = try await NfsBrowsablePlugin(session: session, name: name)
                addShare(share)
            } catch { presentError(error) }
        }
    }

    private func addSftpShare() {
        guard let portValue = parsedSftpPort else {
            presentError(MankaiErrorCode.browseSftpInvalidConnectionConfiguration.makeError())
            return
        }

        isAdding = true
        Task { @MainActor in
            defer { isAdding = false }

            do {
                let configuration = try SftpConnectionConfiguration(
                    host: sftpHost, port: portValue, username: sftpUsername, password: sftpPassword)
                let session = SftpSession(configuration: configuration)
                let share = try await SftpBrowsablePlugin(session: session, name: name)
                addShare(share)
            } catch { presentError(error) }
        }
    }

    private func addWebDavShare() {
        isAdding = true
        Task { @MainActor in
            defer { isAdding = false }

            do {
                let configuration = try WebDavConnectionConfiguration(
                    baseURL: webDavServerURL, username: webDavUsername, password: webDavPassword)
                let session = WebDavSession(configuration: configuration)
                let share = try await WebDavBrowsablePlugin(session: session, name: name)
                addShare(share)
            } catch { presentError(error) }
        }
    }

    private func addOpdsShare() {
        isAdding = true
        Task { @MainActor in
            defer { isAdding = false }

            do {
                let configuration = try OpdsConnectionConfiguration(
                    catalogURL: opdsCatalogURL, username: opdsUsername, password: opdsPassword)
                let session = OpdsSession(configuration: configuration)
                let share = try await OpdsBrowsablePlugin(session: session, name: name)
                addShare(share)
            } catch { presentError(error) }
        }
    }

    private var parsedPort: Int? {
        guard let portValue = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
            (1...65535).contains(portValue)
        else { return nil }
        return portValue
    }

    private var parsedSftpPort: Int? {
        guard let portValue = Int(sftpPort.trimmingCharacters(in: .whitespacesAndNewlines)),
            (1...65535).contains(portValue)
        else { return nil }
        return portValue
    }

    private var duplicateShareIsPresented: Binding<Bool> {
        Binding(get: { duplicateShare != nil }, set: { if !$0 { duplicateShare = nil } })
    }

    private func addShare(_ share: BrowsablePlugin) {
        do {
            try browseService.addPlugin(share)
            dismiss()
        } catch let error where MankaiErrorCode.pluginDuplicateId.matches(error) {
            duplicateShare = share
        } catch { presentError(error) }
    }

    private func resolveDuplicateShare(with conflictResolution: BrowsePluginAddConflictResolution) {
        guard let duplicateShare else { return }
        self.duplicateShare = nil

        do {
            try browseService.addPlugin(duplicateShare, conflictResolution: conflictResolution)
            dismiss()
        } catch { presentError(error) }
    }

    private func presentError(_ error: Error, title: LocalizedStringKey = "failedToAddFiles") {
        errorTitle = title
        errorMessage = error.localizedDescription
    }
}
