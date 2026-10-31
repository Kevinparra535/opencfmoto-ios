// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) QrScanActivity.kt + the pairing parts of MainActivity.kt /
// GarageActivity.kt (session-network.md §2.11–§2.12, app-features §7.5.5).
//
// Camera QR scanner (VisionKit, AVFoundation fallback) with 1x/2x/3x zoom, "Import QR from photo"
// and "Enter Wi-Fi manually". Every decoded text goes to `GarageModel.pair(rawQR:)`: a pairing QR
// saves + selects the bike (haptic, banner "Added <name>", `onPaired`, dismiss); anything else
// shows the parser hint ("that is the Carbit app-download QR…", "Invalid QR") and keeps
// scanning. Whoever presented the scanner starts Connect / Mirror once it is dismissed.

import SwiftUI
import UIKit
import AVFoundation
import VisionKit
import PhotosUI
import OpenCfMotoAppModel
import OpenCfMotoCore

struct ScanScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private let showsCancelButton: Bool
    private let onPaired: ((GarageBike) -> Void)?

    @State private var camera: ScanCameraState = .checking
    @State private var zoom: Double = 1
    @State private var maxZoom: Double = 3
    @State private var hint: String?
    @State private var lastRejected: ScanRejectedCode?
    @State private var finished = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isImportingPhoto = false
    @State private var importTask: Task<Void, Never>?
    @State private var showsManualEntry = false
    @State private var manuallyPairedBike: GarageBike?
    /// Results that arrive after the scanner left the screen are ignored.
    @State private var isVisible = false

    /// - Parameters:
    ///   - showsCancelButton: true when presented modally (a sheet) rather than pushed.
    ///   - onPaired: called with the saved bike right before the scanner dismisses itself.
    init(showsCancelButton: Bool = false, onPaired: ((GarageBike) -> Void)? = nil) {
        self.showsCancelButton = showsCancelButton
        self.onPaired = onPaired
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height * 1.15
            Group {
                if wide {
                    HStack(spacing: 0) {
                        cameraPanel
                        ScrollView { controls.padding(Theme.padding) }
                            .frame(width: min(340, geo.size.width * 0.42))
                    }
                } else {
                    VStack(spacing: 0) {
                        cameraPanel
                        controls
                            .padding(Theme.padding)
                    }
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Scan the dash QR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancelButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { @MainActor in
            await resolveCamera()
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            importTask?.cancel()
            importTask = nil
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings (camera allowed there): re-check.
            if phase == .active, camera == .denied {
                Task { @MainActor in await resolveCamera() }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            importQR(from: item)
        }
        .sheet(isPresented: $showsManualEntry, onDismiss: {
            guard let bike = manuallyPairedBike else { return }
            manuallyPairedBike = nil
            finish(with: bike)
        }) {
            ManualWifiPairingSheet { bike in
                manuallyPairedBike = bike
            }
        }
    }

    // MARK: - Camera

    private var cameraPanel: some View {
        ZStack {
            Color.black
            cameraContent
            VStack {
                Text("Point the camera at the bike's MotoPlay QR\n\nIf it won't scan — try the iOS / CarPlay QR, or enter Wi-Fi manually (TRK).")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(12)
                Spacer(minLength: 0)
                if let hint {
                    Label {
                        Text(verbatim: hint)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Theme.error.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(12)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
        .clipped()
    }

    @ViewBuilder
    private var cameraContent: some View {
        let scanning = !finished && !showsManualEntry && !isImportingPhoto && scenePhase == .active
        switch camera {
        case .checking:
            ProgressView()
                .tint(.white)
        case .dataScanner:
            QRDataScannerView(zoom: zoom, maxZoom: $maxZoom, isActive: scanning) { text in
                handle(text, fromPhoto: false)
            }
            .ignoresSafeArea(edges: .bottom)
        case .captureSession:
            QRCaptureSessionView(zoom: zoom, maxZoom: $maxZoom, isActive: scanning) { text in
                handle(text, fromPhoto: false)
            }
        case .denied:
            cameraMessage(
                title: "Camera access is off",
                message: "OpenCfMoto uses the camera only to scan the pairing QR on your dash; frames are never stored. Allow it in Settings, or import the QR from a photo or enter the Wi-Fi manually.",
                showsSettings: true)
        case .restricted:
            cameraMessage(
                title: "Camera access is restricted",
                message: "This iPhone does not allow camera access (Screen Time or a profile). Import the QR from a photo or enter the Wi-Fi manually.",
                showsSettings: false)
        case .unavailable:
            cameraMessage(
                title: "No camera available",
                message: "Import the QR from a photo (a screenshot of the dash works) or enter the Wi-Fi manually.",
                showsSettings: false)
        }
    }

    private func cameraMessage(title: LocalizedStringKey, message: LocalizedStringKey, showsSettings: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if showsSettings {
                Button("Open Settings") { model.permissions.openAppSettings() }
                    .buttonStyle(TonalButtonStyle())
                    .frame(maxWidth: 260)
            }
        }
        .padding(24)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 12) {
            if camera == .dataScanner || camera == .captureSession {
                HStack(spacing: 10) {
                    ForEach([1.0, 2.0, 3.0], id: \.self) { factor in
                        let label = "\(Int(factor))x"
                        Button {
                            zoom = factor
                        } label: {
                            Text(verbatim: label)
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .foregroundStyle(abs(zoom - factor) < 0.01 ? Color.white : Theme.text)
                                .background(abs(zoom - factor) < 0.01 ? Theme.brand : Theme.surfaceHigh,
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(factor > maxZoom + 0.01)
                        .opacity(factor > maxZoom + 0.01 ? 0.4 : 1)
                        .accessibilityLabel(Text("Zoom \(label)"))
                        .accessibilityAddTraits(abs(zoom - factor) < 0.01 ? .isSelected : [])
                    }
                }
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label {
                    if isImportingPhoto {
                        Text("Reading the photo…")
                    } else {
                        Text("Import QR from photo")
                    }
                } icon: {
                    Image(systemName: "photo")
                }
            }
            .buttonStyle(TonalButtonStyle())
            .disabled(isImportingPhoto || finished)

            Button {
                showsManualEntry = true
            } label: {
                Label("Enter Wi-Fi manually", systemImage: "keyboard")
            }
            .buttonStyle(TonalButtonStyle())
            .disabled(finished)
        }
    }

    // MARK: - Results

    @MainActor
    private func resolveCamera() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            camera = Self.availableReader()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            camera = granted ? Self.availableReader() : .denied
        case .denied:
            camera = .denied
        case .restricted:
            camera = .restricted
        @unknown default:
            camera = .denied
        }
    }

    @MainActor
    private static func availableReader() -> ScanCameraState {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            return .dataScanner
        }
        if AVCaptureDevice.default(for: .video) != nil {
            return .captureSession
        }
        return .unavailable
    }

    private func importQR(from item: PhotosPickerItem) {
        importTask?.cancel()
        isImportingPhoto = true
        importTask = Task { @MainActor in
            defer { isImportingPhoto = false }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    hint = String(localized: "Invalid QR")
                    return
                }
                let text = await Task.detached(priority: .userInitiated) {
                    QRPhotoDecoder.firstQRCode(in: data)
                }.value
                guard !Task.isCancelled else { return }
                if let text {
                    handle(text, fromPhoto: true)
                } else {
                    hint = String(localized: "Invalid QR")
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            } catch {
                if !Task.isCancelled { hint = String(localized: "QR photo failed") }
            }
        }
    }

    /// One decoded QR text (camera or photo) → pairing.
    private func handle(_ raw: String, fromPhoto: Bool) {
        guard isVisible, !finished, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // The camera reports the same rejected code many times per second: hint once.
        if !fromPhoto, let rejected = lastRejected, rejected.raw == raw,
           Date().timeIntervalSince(rejected.at) < 3 {
            return
        }
        switch model.garage.pair(rawQR: raw) {
        case .paired(let bike):
            finish(with: bike)
        case .invalid(let reason):
            lastRejected = ScanRejectedCode(raw: raw, at: Date())
            hint = reason.isEmpty ? String(localized: "Invalid QR") : reason
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    private func finish(with bike: GarageBike) {
        guard !finished else { return }
        finished = true
        hint = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        model.showBanner(String(localized: "Added \(bike.name)"))
        onPaired?(bike)
        dismiss()
    }
}

enum ScanCameraState: Equatable {
    case checking
    case dataScanner
    case captureSession
    case denied
    case restricted
    case unavailable
}

struct ScanRejectedCode: Equatable {
    var raw: String
    var at: Date
}

#Preview {
    NavigationStack {
        ScanScreen(showsCancelButton: true)
    }
    .environment(AppModel.preview())
    .preferredColorScheme(.dark)
}
