// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GarageActivity.kt:177-240 (the per-bike action list: Use this
// bike, Rename, Add / Change / Remove photo, Remove bike) plus an iOS details card: SSID, password
// (hidden, reveal + copy), MAC, model id and the dash canvas learned on the last connection.
// Fuel MVP: the «Combustible» section (GarageFuelSection.swift) between "Dash" and "Remove bike";
// `scrollAnchor` "fuel" scrolls to it (`-uiScreen fuel`).

import SwiftUI
import PhotosUI
import OpenCfMotoAppModel
import OpenCfMotoCore

struct GarageBikeDetailView: View {
    let bikeID: String
    /// A section to scroll to once after the first layout pass ("fuel": «Combustible»).
    var scrollAnchor: String?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renameText = ""
    @State private var showsRename = false
    @State private var showsRemoveConfirmation = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isSavingPhoto = false
    @State private var scrollTarget: String?

    var body: some View {
        Group {
            if let bike = model.garage.bikes.first(where: { $0.id == bikeID }) {
                details(for: bike)
            } else {
                ContentUnavailableView("Bike removed", systemImage: "trash",
                                       description: Text("This bike is no longer in the garage."))
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private func details(for bike: GarageBike) -> some View {
        let garage = model.garage
        let isActive = garage.selected?.id == bike.id
        let qr = garage.qr(for: bike.id)
        let photoURL = garage.photoURL(for: bike.id)
        let canvas = garage.learnedCanvas(for: bike.id)
        return ScrollViewReader { proxy in
            list(for: bike, isActive: isActive, qr: qr, photoURL: photoURL, canvas: canvas)
                .task { await armScrollAnchor() }
                .onChange(of: scrollTarget) { _, row in
                    guard let row else { return }
                    withAnimation {
                        proxy.scrollTo(row, anchor: row == GarageFuelSection.anchorID ? GarageFuelSection.anchorPoint : .top)
                    }
                }
        }
    }

    /// Scrolls to `scrollAnchor` once the list is laid out (CI screenshots: `-uiScreen fuel`).
    private func armScrollAnchor() async {
        guard let anchor = scrollAnchor, scrollTarget == nil else { return }
        try? await Task.sleep(for: .milliseconds(500))
        scrollTarget = anchor
    }

    private func list(for bike: GarageBike, isActive: Bool, qr: BikeQR?, photoURL: URL?,
                      canvas: VideoCanvas?) -> some View {
        List {
            Section {
                BikePhotoView(url: photoURL, maxPixel: 1200)
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if isSavingPhoto {
                            ProgressView()
                                .tint(.white)
                                .padding(10)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: bike.name)
                        .font(.title2.bold())
                        .foregroundStyle(Theme.text)
                    if isActive {
                        Label("Active bike", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.brand)
                    }
                }
                .listRowBackground(Color.clear)
            }

            Section {
                if !isActive {
                    Button {
                        model.garage.select(bike.id)
                        model.showBanner(String(localized: "Selected \(bike.name)"))
                    } label: {
                        Label("Use this bike", systemImage: "checkmark.circle")
                    }
                }
                Button {
                    renameText = bike.name
                    showsRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    if photoURL == nil {
                        Label("Add photo", systemImage: "photo")
                    } else {
                        Label("Change photo", systemImage: "photo")
                    }
                }
                .disabled(isSavingPhoto)
                if photoURL != nil {
                    Button(role: .destructive) {
                        model.garage.removePhoto(bike.id)
                    } label: {
                        Label("Remove photo", systemImage: "minus.circle")
                    }
                }
            }
            .listRowBackground(Theme.surface)

            Section {
                MainCopyableValueRow(title: "Wi-Fi name (SSID)", value: bike.ssid) {
                    model.showBanner(String(localized: "Copied"))
                }
                if let password = qr?.password, !password.isEmpty {
                    MainCopyableValueRow(title: "Password", value: password, isSecret: true) {
                        model.showBanner(String(localized: "Password copied — it stays on this iPhone for 2 minutes"))
                    }
                }
                if let auth = qr?.auth, !auth.isEmpty {
                    LabeledContent("Security") {
                        Text(verbatim: auth.uppercased())
                    }
                }
                if let mac = bike.mac ?? qr?.mac, !mac.isEmpty {
                    LabeledContent("MAC address") {
                        Text(verbatim: mac).monospaced()
                    }
                }
            } header: {
                Text("Wi-Fi")
            }
            .listRowBackground(Theme.surface)

            Section {
                LabeledContent("Model ID") {
                    Text(verbatim: qr?.modelId ?? "—")
                }
                LabeledContent("Learned canvas") {
                    if let canvas {
                        Text(verbatim: MainStrings.canvasText(width: canvas.width, height: canvas.height))
                    } else {
                        Text("Not connected yet")
                    }
                }
                if let profile = bike.profileHint {
                    LabeledContent("Dash profile") {
                        Text(verbatim: model.settings.profileName(profile))
                    }
                }
            } header: {
                Text("Dash")
            } footer: {
                Text("The canvas is the picture size this dash asked for on the last connection.")
            }
            .listRowBackground(Theme.surface)

            GarageFuelSection(bikeID: bike.id)

            Section {
                Button(role: .destructive) {
                    showsRemoveConfirmation = true
                } label: {
                    Label("Remove bike", systemImage: "trash")
                }
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(Text(verbatim: bike.name))
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            savePhoto(item)
        }
        .alert("Rename bike", isPresented: $showsRename) {
            TextField("Bike name", text: $renameText)
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { model.garage.rename(bike.id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(Text("Remove \(bike.name)?"), isPresented: $showsRemoveConfirmation) {
            Button("Remove", role: .destructive) {
                model.garage.remove(bike.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This forgets its pairing, photo, settings and fuel log. You can re-scan the dash QR or enter Wi-Fi again later.")
        }
    }

    private func savePhoto(_ item: PhotosPickerItem) {
        isSavingPhoto = true
        let id = bikeID
        Task { @MainActor in
            defer { isSavingPhoto = false }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    model.showBanner(String(localized: "Couldn't read that image"))
                    return
                }
                let jpeg = await Task.detached(priority: .userInitiated) {
                    BikePhotoProcessing.jpegData(fromImageData: data)
                }.value
                guard let jpeg else {
                    model.showBanner(String(localized: "Couldn't read that image"))
                    return
                }
                try model.garage.setPhoto(id, imageData: jpeg, fileExtension: "jpg")
            } catch {
                model.showBanner(String(localized: "Couldn't read that image"))
            }
        }
    }
}

#Preview {
    NavigationStack {
        GarageBikeDetailView(bikeID: "preview")
    }
    .environment(AppModel.preview())
    .preferredColorScheme(.dark)
}
