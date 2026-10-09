//
//  QRCodeScannerView.swift
//  mankai
//
//  Created by Travis XU on 9/10/2026.
//

import AVFoundation
import SwiftUI
import UIKit

struct QRCodeScannerView: UIViewRepresentable {
    let isScanning: Bool
    let isTorchOn: Bool
    let onSuccess: @MainActor @Sendable (String) -> Void
    let onFailure: @MainActor @Sendable () -> Void
    let onTorchStateChange: @MainActor @Sendable (Bool, Bool) -> Void

    func makeCoordinator() -> CaptureSession {
        CaptureSession(
            onSuccess: onSuccess, onFailure: onFailure, onTorchStateChange: onTorchStateChange)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.attach(session: context.coordinator.session, device: context.coordinator.device)
        context.coordinator.setScanning(isScanning, torchOn: isTorchOn)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.setScanning(isScanning, torchOn: isTorchOn)
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: CaptureSession) {
        view.detach()
        coordinator.invalidate()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        private var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?
        private var runningObservation: NSKeyValueObservation?

        func attach(session: AVCaptureSession, device: AVCaptureDevice?) {
            backgroundColor = .black
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.session = session

            if let device {
                rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                    device: device, previewLayer: previewLayer)
                rotationObservation = rotationCoordinator?
                    .observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new])
                { [weak self] _, _ in Task { @MainActor in self?.updateRotation() } }
            }

            runningObservation = session.observe(\.isRunning, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateRotation() }
            }
        }

        func detach() {
            rotationObservation = nil
            runningObservation = nil
            rotationCoordinator = nil
            previewLayer.session = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateRotation()
        }

        private func updateRotation() {
            guard let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview,
                let connection = previewLayer.connection,
                connection.isVideoRotationAngleSupported(angle)
            else { return }
            connection.videoRotationAngle = angle
        }
    }

    /// Capture state, configuration, and metadata callbacks all use the same serial queue.
    nonisolated final class CaptureSession: NSObject, AVCaptureMetadataOutputObjectsDelegate,
        @unchecked Sendable
    {
        let session = AVCaptureSession()
        let device = AVCaptureDevice.default(for: .video)

        private let sessionQueue = DispatchQueue(label: "app.mankai.qrScanner")
        private let metadataOutput = AVCaptureMetadataOutput()
        private let onSuccess: @MainActor @Sendable (String) -> Void
        private let onFailure: @MainActor @Sendable () -> Void
        private let onTorchStateChange: @MainActor @Sendable (Bool, Bool) -> Void
        private var runtimeErrorObserver: NSObjectProtocol?
        private var torchAvailabilityObservation: NSKeyValueObservation?
        private var torchModeObservation: NSKeyValueObservation?
        private var lastTorchAvailable = false
        private var lastTorchOn = false
        private var isConfigured = false
        private var isScanning = false
        private var hasDeliveredCode = false
        private var hasFailed = false
        private var isInvalidated = false

        init(
            onSuccess: @escaping @MainActor @Sendable (String) -> Void,
            onFailure: @escaping @MainActor @Sendable () -> Void,
            onTorchStateChange: @escaping @MainActor @Sendable (Bool, Bool) -> Void
        ) {
            self.onSuccess = onSuccess
            self.onFailure = onFailure
            self.onTorchStateChange = onTorchStateChange
            super.init()

            runtimeErrorObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async { self.fail() }
            }

            torchAvailabilityObservation = device?
                .observe(\.isTorchAvailable, options: [.new]) { [weak self] _, _ in
                    guard let self else { return }
                    self.sessionQueue.async { self.publishTorchState() }
                }
            torchModeObservation = device?
                .observe(\.torchMode, options: [.new]) { [weak self] _, _ in
                    guard let self else { return }
                    self.sessionQueue.async { self.publishTorchState() }
                }
        }

        deinit {
            if let runtimeErrorObserver {
                NotificationCenter.default.removeObserver(runtimeErrorObserver)
            }
        }

        func setScanning(_ scanning: Bool, torchOn: Bool) {
            sessionQueue.async { [self] in
                guard !isInvalidated, !hasFailed else { return }

                if scanning {
                    guard !hasDeliveredCode else { return }
                    if !isConfigured, !configureSession() {
                        fail()
                        return
                    }

                    isScanning = true
                    if !session.isRunning { session.startRunning() }
                    setTorch(torchOn)
                } else {
                    stopScanning()
                }
            }
        }

        func invalidate() {
            sessionQueue.async { [self] in
                guard !isInvalidated else { return }
                isInvalidated = true
                torchAvailabilityObservation = nil
                torchModeObservation = nil
                stopScanning()
                metadataOutput.setMetadataObjectsDelegate(nil, queue: nil)

                if let runtimeErrorObserver {
                    NotificationCenter.default.removeObserver(runtimeErrorObserver)
                    self.runtimeErrorObserver = nil
                }

                session.beginConfiguration()
                for input in session.inputs { session.removeInput(input) }
                for output in session.outputs { session.removeOutput(output) }
                session.commitConfiguration()
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard isScanning, !hasDeliveredCode, !isInvalidated else { return }

            for case let object as AVMetadataMachineReadableCodeObject in metadataObjects {
                guard object.type == .qr, let code = object.stringValue else { continue }
                hasDeliveredCode = true
                isScanning = false
                sessionQueue.async { [self] in stopScanning() }
                Task { @MainActor [onSuccess] in onSuccess(code) }
                return
            }
        }

        private func configureSession() -> Bool {
            guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
                return false
            }

            session.beginConfiguration()
            defer { session.commitConfiguration() }

            guard session.canAddInput(input) else { return false }
            session.addInput(input)

            guard session.canAddOutput(metadataOutput) else { return false }
            session.addOutput(metadataOutput)
            guard metadataOutput.availableMetadataObjectTypes.contains(.qr) else { return false }
            metadataOutput.metadataObjectTypes = [.qr]
            metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)
            isConfigured = true
            return true
        }

        private func stopScanning() {
            isScanning = false
            setTorch(false)
            if session.isRunning { session.stopRunning() }
        }

        private func setTorch(_ enabled: Bool) {
            guard let device, device.hasTorch else {
                publishTorchState()
                return
            }

            let mode: AVCaptureDevice.TorchMode = enabled && device.isTorchAvailable ? .on : .off
            if device.isTorchModeSupported(mode), device.torchMode != mode {
                do {
                    try device.lockForConfiguration()
                    device.torchMode = mode
                    device.unlockForConfiguration()
                } catch {
                    publishTorchState(force: true)
                    return
                }
            }
            publishTorchState()
        }

        private func publishTorchState(force: Bool = false) {
            guard !isInvalidated else { return }
            let available =
                isScanning && device?.hasTorch == true && device?.isTorchAvailable == true
                && device?.isTorchModeSupported(.on) == true
            let enabled = available && device?.torchMode == .on
            guard force || available != lastTorchAvailable || enabled != lastTorchOn else { return }
            lastTorchAvailable = available
            lastTorchOn = enabled
            Task { @MainActor [onTorchStateChange] in onTorchStateChange(available, enabled) }
        }

        private func fail() {
            guard !hasFailed, !isInvalidated else { return }
            hasFailed = true
            stopScanning()
            Task { @MainActor [onFailure] in onFailure() }
        }
    }
}
