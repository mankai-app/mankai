//
//  SourceQRCodeScannerModal.swift
//  mankai
//
//  Created by Travis XU on 9/10/2026.
//

import AVFoundation
import PhotosUI
import SwiftUI
import Vision

struct SourceQRCodeScannerModal: View {
    @Environment(\.scenePhase) private var scenePhase

    let onAdded: () -> Void

    @State private var cameraAuthorized = false
    @State private var cameraAccessDenied = false
    @State private var isScanning = false
    @State private var didScanCode = false
    @State private var isPreparingCamera = false
    @State private var errorMessage: String?
    @State private var sourceImportRequest: SourceImportRequest?
    @State private var showInvalidLink = false
    @State private var scannerSessionID = UUID()
    @State private var isVisible = false
    @State private var useManualInput = false
    @State private var importLink = ""
    @State private var isTorchOn = false
    @State private var isTorchActive = false
    @State private var isTorchAvailable = false
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isReadingPhoto = false
    @State private var photoImportID: UUID?
    @State private var photoErrorMessage: String?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        let scanSessionID = scannerSessionID

        ZStack {
            if useManualInput {
                Form {
                    Section {
                        TextField("sourceImportLinkPlaceholder", text: $importLink, axis: .vertical)
                            .lineLimit(3...8).keyboardType(.URL).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().focused($isInputFocused)
                            .submitLabel(.continue).onSubmit { importSources(from: importLink) }
                    } header: {
                        Text("importLink")
                    } footer: {
                        Text("sourceImportLinkHint")
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("scanQRCode", systemImage: "qrcode.viewfinder")
                } description: {
                    Text(errorMessage)
                } actions: {
                    if !cameraAccessDenied { Button("retry") { Task { await prepareCamera() } } }
                }
            } else if cameraAuthorized {
                QRCodeScannerView(
                    isScanning: isScanning, isTorchOn: isTorchOn,
                    onSuccess: { code in
                        guard isVisible, isScanning, !useManualInput, !didScanCode,
                            !showPhotoPicker, !isReadingPhoto, scannerSessionID == scanSessionID
                        else { return }
                        didScanCode = true
                        isScanning = false
                        importSources(from: code)
                    },
                    onFailure: {
                        guard isVisible, isScanning, !useManualInput, !didScanCode,
                            !showPhotoPicker, !isReadingPhoto, scannerSessionID == scanSessionID
                        else { return }
                        isScanning = false
                        errorMessage = String(localized: "failedToScanQRCode")
                    },
                    onTorchStateChange: { available, enabled in
                        guard isVisible, !useManualInput, scannerSessionID == scanSessionID else {
                            return
                        }
                        if isTorchAvailable != available { isTorchAvailable = available }
                        if isTorchActive != enabled { isTorchActive = enabled }
                        if !available, isTorchOn { isTorchOn = false }
                    }
                )
                .id(scannerSessionID).ignoresSafeArea(edges: .bottom)
                .overlay {
                    if isScanning {
                        Image("ScanIcon").resizable().scaledToFit().frame(width: 300, height: 300)
                            .foregroundStyle(.white.opacity(0.8)).allowsHitTesting(false)
                            .padding(.bottom, 100)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { scannerOverlay }
        .navigationTitle(useManualInput ? Text("importLink") : Text("scanQRCode"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    toggleManualInput()
                } label: {
                    Image(systemName: useManualInput ? "qrcode.viewfinder" : "keyboard")
                }
            }

            if useManualInput {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("continue") { importSources(from: importLink) }
                        .disabled(
                            importLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationDestination(item: $sourceImportRequest) { request in
            AddSourcesView(sources: request.sources, onAdded: onAdded)
        }
        .alert("invalidUrl", isPresented: $showInvalidLink) {
            if useManualInput {
                Button("ok", role: .cancel) { isInputFocused = true }
            } else {
                Button("retry", role: .cancel) {
                    showInvalidLink = false
                    didScanCode = false
                    Task { await prepareCamera() }
                }
            }
        } message: {
            Text("invalidSourceImportLink")
        }
        .alert(
            "failedToScanQRCode",
            isPresented: Binding(
                get: { photoErrorMessage != nil }, set: { if !$0 { photoErrorMessage = nil } })
        ) {
            Button("ok", role: .cancel) {
                photoErrorMessage = nil
                Task { await prepareCamera() }
            }
        } message: {
            Text(photoErrorMessage ?? "")
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: showPhotoPicker) { _, isPresented in
            if !isPresented, selectedPhoto == nil { Task { await prepareCamera() } }
        }
        .task(id: showPhotoPicker ? nil : selectedPhoto) {
            if !showPhotoPicker, let selectedPhoto { await importPhoto(selectedPhoto) }
        }
        .onAppear { isVisible = true }
        .task(id: isVisible && sourceImportRequest == nil) {
            guard isVisible, sourceImportRequest == nil else { return }
            didScanCode = false
            if useManualInput { isInputFocused = true } else { await prepareCamera() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await prepareCamera() } } else { isScanning = false }
        }
        .onDisappear {
            isVisible = false
            isScanning = false
            isTorchOn = false
            isTorchActive = false
            isTorchAvailable = false
            photoImportID = nil
            isReadingPhoto = false
            didScanCode = true
            isInputFocused = false
        }
    }

    @ViewBuilder private var scannerOverlay: some View {
        if !useManualInput {
            VStack(spacing: 20) {
                if cameraAuthorized, errorMessage == nil {
                    Text("sourceQRCodeHint").font(.callout).multilineTextAlignment(.center)
                        .padding().adaptiveGlassBackground(in: RoundedRectangle(cornerRadius: 12))
                }

                let buttons = HStack(spacing: 20) {
                    if isTorchAvailable {
                        Button {
                            isTorchOn.toggle()
                        } label: {
                            Image(
                                systemName: isTorchActive
                                    ? "flashlight.on.fill" : "flashlight.off.fill"
                            )
                            .frame(width: 32, height: 32)

                        }
                        .tint(isTorchActive ? .yellow : nil).disabled(!isScanning)
                    }

                    Button {
                        isScanning = false
                        isTorchOn = false
                        showPhotoPicker = true
                    } label: {
                        Group {
                            if isReadingPhoto { ProgressView() } else { Image(systemName: "photo") }
                        }
                        .frame(width: 32, height: 32)
                    }
                    .disabled(isReadingPhoto || isPreparingCamera)
                }

                if #available(iOS 26.0, *) {
                    buttons.buttonStyle(.glass)
                } else {
                    buttons.buttonStyle(.bordered)
                }
            }
            .padding()
        }
    }

    private func toggleManualInput() {
        useManualInput.toggle()
        isScanning = false
        isTorchOn = false
        isTorchActive = false
        isTorchAvailable = false
        photoImportID = nil
        selectedPhoto = nil
        isReadingPhoto = false
        isInputFocused = useManualInput

        if !useManualInput {
            didScanCode = false
            Task { await prepareCamera() }
        }
    }

    private func importSources(from link: String) {
        guard let request = SourceImportRequest(link: link) else {
            showInvalidLink = true
            return
        }

        isScanning = false
        isTorchOn = false
        isInputFocused = false
        sourceImportRequest = request
    }

    private func importPhoto(_ photo: PhotosPickerItem) async {
        guard isVisible, !useManualInput else { return }
        let importID = UUID()
        photoImportID = importID
        isReadingPhoto = true
        isScanning = false
        isTorchOn = false

        defer {
            if photoImportID == importID {
                photoImportID = nil
                isReadingPhoto = false
                selectedPhoto = nil
            }
        }

        do {
            guard let data = try await photo.loadTransferable(type: Data.self) else {
                guard !Task.isCancelled, isVisible, photoImportID == importID else { return }
                photoErrorMessage = String(localized: "failedToLoadSelectedImage")
                return
            }

            try Task.checkCancellation()
            let detection = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                try VNImageRequestHandler(data: data, options: [:]).perform([request])
                try Task.checkCancellation()
                return (request.results ?? []).compactMap(\.payloadStringValue)
            }
            let links = try await withTaskCancellationHandler {
                try await detection.value
            } onCancel: {
                detection.cancel()
            }

            guard !Task.isCancelled, isVisible, !useManualInput, photoImportID == importID else {
                return
            }
            guard !links.isEmpty else {
                photoErrorMessage = String(localized: "noQRCodeFoundInPhoto")
                return
            }

            let urls = links.compactMap {
                URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            guard let request = SourceImportRequest(urls: urls) else {
                showInvalidLink = true
                return
            }

            didScanCode = true
            sourceImportRequest = request
        } catch {
            guard !Task.isCancelled, isVisible, photoImportID == importID else { return }
            photoErrorMessage = String(localized: "failedToScanQRCode")
        }
    }

    private func prepareCamera() async {
        guard isVisible, !useManualInput, !didScanCode, !isPreparingCamera, !showPhotoPicker,
            selectedPhoto == nil, !isReadingPhoto, photoErrorMessage == nil, !showInvalidLink,
            sourceImportRequest == nil
        else { return }
        isPreparingCamera = true
        defer { isPreparingCamera = false }

        isScanning = false
        isTorchOn = false
        isTorchAvailable = false
        cameraAuthorized = false
        errorMessage = nil
        cameraAccessDenied = false

        guard AVCaptureDevice.default(for: .video) != nil else {
            errorMessage = String(localized: "cameraUnavailable")
            return
        }

        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) { case .authorized:
            authorized = true
            case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
            default: authorized = false
        }

        guard !Task.isCancelled, isVisible, !useManualInput, !didScanCode, !showPhotoPicker,
            selectedPhoto == nil, !isReadingPhoto
        else { return }

        cameraAuthorized = authorized
        cameraAccessDenied = !authorized
        if authorized {
            scannerSessionID = UUID()
            isScanning = scenePhase == .active
        } else {
            errorMessage = String(localized: "cameraAccessRequired")
        }
    }
}
