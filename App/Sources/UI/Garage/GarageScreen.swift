// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GarageActivity.kt + res/layout/activity_garage.xml
// (app-features §4.2, §4.5): every remembered bike with its photo, name and SSID; the active one is
// the bike Connect uses. Tap → details (rename, photo, Wi-Fi, learned canvas, remove); swipe /
// context menu for "Use this bike" and "Remove bike"; add bikes by QR or manual Wi-Fi.

import SwiftUI
import OpenCfMotoAppModel
import OpenCfMotoCore

struct GarageScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showsScanner = false
    @State private var showsManualEntry = false
    @State private var manuallyAddedBike: GarageBike?
    @State private var bikePendingRemoval: GarageBike?

    var body: some View {
        let garage = model.garage
        List {
            Section {
                Text("Each bike keeps its own name, photo, video quality, screen fit, power mode and button mapping. Tap a bike to make it active or edit it.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }

            if garage.bikes.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label {
                            Text("No bikes yet")
                        } icon: {
                            MainRideGlyph().frame(width: 44, height: 44).foregroundStyle(Theme.brand)
                        }
                    } description: {
                        Text("Scan your dash QR, or enter Wi-Fi name + password (TRK).")
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(garage.bikes) { bike in
                        let isActive = bike.id == garage.selected?.id
                        NavigationLink {
                            GarageBikeDetailView(bikeID: bike.id)
                        } label: {
                            GarageBikeRow(bike: bike, isActive: isActive, photoURL: garage.photoURL(for: bike.id))
                        }
                        .listRowBackground(isActive ? Theme.surfaceHigh : Theme.surface)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if !isActive {
                                Button {
                                    select(bike)
                                } label: {
                                    Label("Use this bike", systemImage: "checkmark.circle")
                                }
                                .tint(Theme.brand)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                bikePendingRemoval = bike
                            } label: {
                                Label("Remove bike", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            if !isActive {
                                Button {
                                    select(bike)
                                } label: {
                                    Label("Use this bike", systemImage: "checkmark.circle")
                                }
                            }
                            Button(role: .destructive) {
                                bikePendingRemoval = bike
                            } label: {
                                Label("Remove bike", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Bikes")
                }
            }

            Section {
                Button {
                    showsScanner = true
                } label: {
                    Label("Scan new bike", systemImage: "qrcode.viewfinder")
                }
                Button {
                    showsManualEntry = true
                } label: {
                    Label("Enter Wi-Fi manually", systemImage: "keyboard")
                }
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Garage")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showsScanner = true
                    } label: {
                        Label("Scan new bike", systemImage: "qrcode.viewfinder")
                    }
                    Button {
                        showsManualEntry = true
                    } label: {
                        Label("Enter Wi-Fi manually", systemImage: "keyboard")
                    }
                } label: {
                    Label("Add bike", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showsScanner) {
            NavigationStack {
                ScanScreen(showsCancelButton: true)
            }
        }
        .sheet(isPresented: $showsManualEntry, onDismiss: {
            guard let bike = manuallyAddedBike else { return }
            manuallyAddedBike = nil
            model.showBanner(String(localized: "Added \(bike.name)"))
        }) {
            ManualWifiPairingSheet { bike in
                manuallyAddedBike = bike
            }
        }
        .alert(removalTitle, isPresented: removalBinding, presenting: bikePendingRemoval) { bike in
            Button("Remove", role: .destructive) {
                model.garage.remove(bike.id)
                bikePendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                bikePendingRemoval = nil
            }
        } message: { _ in
            Text("This forgets its pairing, photo and settings. You can re-scan the dash QR or enter Wi-Fi again later.")
        }
    }

    private var removalTitle: Text {
        if let bike = bikePendingRemoval {
            return Text("Remove \(bike.name)?")
        }
        return Text(verbatim: "")
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { bikePendingRemoval != nil },
                set: { if !$0 { bikePendingRemoval = nil } })
    }

    private func select(_ bike: GarageBike) {
        model.garage.select(bike.id)
        model.showBanner(String(localized: "Selected \(bike.name)"))
    }
}

/// One garage card: photo, name, SSID, active state.
struct GarageBikeRow: View {
    let bike: GarageBike
    let isActive: Bool
    let photoURL: URL?

    var body: some View {
        HStack(spacing: 14) {
            BikePhotoView(url: photoURL, maxPixel: 180)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isActive ? Theme.brand : Theme.outline, lineWidth: isActive ? 2 : 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: bike.name)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(verbatim: bike.ssid)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if isActive {
                    Text("Active bike · tap to edit")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.brand)
                }
            }
            Spacer(minLength: 8)
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.brand)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isActive ? Text("Active bike") : Text(verbatim: ""))
    }
}

#Preview {
    NavigationStack {
        GarageScreen()
    }
    .environment(AppModel.preview())
    .preferredColorScheme(.dark)
}
