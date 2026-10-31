// SPDX-License-Identifier: AGPL-3.0-or-later
// Camera QR readers for the pairing scanner (docs/spec/ios-platform-facts.md §h; Android
// QrScanActivity.kt: back camera, the first QR wins, 1x/2x/3x zoom clamped to the camera range).
// - `QRDataScannerView`: VisionKit DataScannerViewController (guidance, highlighting, pinch zoom).
// - `QRCaptureSessionView`: AVCaptureSession + AVCaptureMetadataOutput fallback for devices where
//   DataScanner is not supported.
// - `QRPhotoDecoder`: "Import QR from photo" (CoreImage QR detector).
// The views only report decoded text; validation and pairing happen in ScanScreen.

import SwiftUI
import UIKit
import AVFoundation
import VisionKit
import Vision
import CoreImage

// MARK: - VisionKit

struct QRDataScannerView: UIViewControllerRepresentable {
    var zoom: Double
    @Binding var maxZoom: Double
    var isActive: Bool
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onCode = onCode
        coordinator.wantsScanning = isActive

        let low = scanner.minZoomFactor
        let high = max(scanner.maxZoomFactor, low)
        let target = min(max(zoom, low), high)
        if abs(scanner.zoomFactor - target) > 0.01 {
            scanner.zoomFactor = target
        }
        if abs(high - maxZoom) > 0.01 {
            DispatchQueue.main.async { maxZoom = high }
        }

        if isActive {
            coordinator.startScanning(scanner)
        } else if scanner.isScanning {
            scanner.stopScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.wantsScanning = false
        if scanner.isScanning {
            scanner.stopScanning()
        }
    }

    /// Delegate callbacks arrive on the main thread (DataScannerViewController is main-actor bound).
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        var wantsScanning = false
        private var retryScheduled = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        /// The scanner may refuse to start before its view is on screen: retry shortly after.
        @MainActor
        func startScanning(_ scanner: DataScannerViewController) {
            guard !scanner.isScanning else { return }
            do {
                try scanner.startScanning()
            } catch {
                guard !retryScheduled else { return }
                retryScheduled = true
                Task { @MainActor [weak self, weak scanner] in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard let self, let scanner else { return }
                    self.retryScheduled = false
                    if self.wantsScanning, !scanner.isScanning {
                        try? scanner.startScanning()
                    }
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            deliver(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            deliver([item])
        }

        private func deliver(_ items: [RecognizedItem]) {
            for item in items {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue, !text.isEmpty {
                    onCode(text)
                    return
                }
            }
        }
    }
}

// MARK: - AVFoundation fallback

struct QRCaptureSessionView: UIViewRepresentable {
    var zoom: Double
    @Binding var maxZoom: Double
    var isActive: Bool
    var onCode: (String) -> Void

    func makeCoordinator() -> QRCaptureCoordinator {
        QRCaptureCoordinator(onCode: onCode)
    }

    func makeUIView(context: Context) -> QRCapturePreviewView {
        let view = QRCapturePreviewView()
        view.backgroundColor = .black
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: QRCapturePreviewView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onCode = onCode
        coordinator.setZoom(zoom)
        coordinator.setRunning(isActive)
        if let high = coordinator.maxZoom, abs(high - maxZoom) > 0.01 {
            DispatchQueue.main.async { maxZoom = high }
        }
    }

    static func dismantleUIView(_ view: QRCapturePreviewView, coordinator: QRCaptureCoordinator) {
        coordinator.shutDown()
    }
}

/// A view whose backing layer is the camera preview.
final class QRCapturePreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
}

/// Owns the capture session. Session start/stop run on a private serial queue (they block);
/// metadata callbacks are delivered on the main queue.
final class QRCaptureCoordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (String) -> Void
    private(set) var maxZoom: Double?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "opencfmoto.qr-capture")
    private var device: AVCaptureDevice?
    private var wantsRunning = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        super.init()
    }

    func attach(to view: QRCapturePreviewView) {
        guard let previewLayer = view.previewLayer else { return }
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        self.device = device
        maxZoom = Double(device.maxAvailableVideoZoomFactor)

        session.beginConfiguration()
        if session.canAddInput(input) {
            session.addInput(input)
        }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
        }
        session.commitConfiguration()

        // Keep the preview upright in portrait and landscape (iOS 17 rotation coordinator).
        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = rotation
        Self.apply(rotation.videoRotationAngleForHorizonLevelPreview, to: previewLayer)
        rotationObservation = rotation.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) {
            [weak previewLayer] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                if let previewLayer { Self.apply(angle, to: previewLayer) }
            }
        }
    }

    private static func apply(_ angle: CGFloat, to layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    func setRunning(_ running: Bool) {
        guard running != wantsRunning, device != nil else { return }
        wantsRunning = running
        let session = self.session
        sessionQueue.async {
            if running {
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func setZoom(_ factor: Double) {
        guard let device else { return }
        let target = min(max(CGFloat(factor), device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        guard abs(device.videoZoomFactor - target) > 0.01 else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = target
            device.unlockForConfiguration()
        } catch {
            // Camera busy: keep the current zoom.
        }
    }

    func shutDown() {
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
        setRunning(false)
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject, code.type == .qr,
                  let text = code.stringValue, !text.isEmpty else { continue }
            onCode(text)
            return
        }
    }
}

// MARK: - Import from photo

enum QRPhotoDecoder {
    /// The first QR payload found in an image file (JPEG / HEIC / PNG data), nil if none.
    static func firstQRCode(in data: Data) -> String? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        guard let detector else { return nil }
        // Huge camera photos: try a ≤ 2048 px copy first (fast), then the original.
        let longest = max(image.extent.width, image.extent.height)
        var candidates: [CIImage] = []
        if longest > 2048, longest.isFinite {
            let scale = 2048 / longest
            candidates.append(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
        }
        candidates.append(image)
        for candidate in candidates {
            for feature in detector.features(in: candidate) {
                if let qr = feature as? CIQRCodeFeature, let text = qr.messageString, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }
}
