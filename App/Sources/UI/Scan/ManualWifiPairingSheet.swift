// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) ManualWifiPairing.kt (app-features §4.3): for dashes that show
// SSID + password instead of a QR (e.g. Benelli TRK). Empty SSID or password keeps the form open
// with "SSID and password are required"; the password is not trimmed (spaces are significant).

import SwiftUI
import OpenCfMotoAppModel
import OpenCfMotoCore

struct ManualWifiPairingSheet: View {
    /// Called with the saved (and selected) bike right before the sheet dismisses itself.
    var onPaired: (GarageBike) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var ssid = ""
    @State private var password = ""
    @State private var bikeName = ""
    @State private var showsPassword = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case ssid, password, name
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Wi-Fi name (SSID)", text: $ssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .ssid)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    HStack {
                        Group {
                            if showsPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focus = .name }
                        Button {
                            showsPassword.toggle()
                        } label: {
                            Image(systemName: showsPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showsPassword ? Text("Hide password") : Text("Show password"))
                    }
                    TextField("Bike name (optional)", text: $bikeName)
                        .focused($focus, equals: .name)
                        .submitLabel(.done)
                        .onSubmit(add)
                } footer: {
                    Text("For dashes that show SSID + password instead of a QR (e.g. Benelli TRK). Use the exact network name from the bike screen.")
                }

                if let error {
                    Section {
                        Label {
                            Text(verbatim: error)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(Theme.error)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Enter bike Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add bike", action: add)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { focus = .ssid }
        }
    }

    private func add() {
        let trimmedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSSID.isEmpty, !password.isEmpty else {
            error = String(localized: "SSID and password are required")
            return
        }
        let name = bikeName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch model.garage.pairManually(ssid: trimmedSSID, password: password, name: name.isEmpty ? nil : name) {
        case .paired(let bike):
            onPaired(bike)
            dismiss()
        case .invalid(let hint):
            error = hint.isEmpty ? String(localized: "Invalid QR") : hint
        }
    }
}

#Preview {
    ManualWifiPairingSheet { _ in }
        .environment(AppModel.preview())
        .preferredColorScheme(.dark)
}
