// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GarageActivity.kt, ManualWifiPairing.kt, MainActivity.kt (scan result)
//
// WAVE-2 SKELETON — owner: logic-data. The PUBLIC SURFACE below is the contract the SwiftUI layer
// codes against: implement the bodies, add private helpers / new files freely, add new public
// members only if needed (report them), never rename or remove existing public members.
//
// Garage (docs/spec/app-features.md §4, session-network.md §2): saved bikes keyed by SSID(+MAC),
// raw QR (contains the Wi-Fi password) only in the SecretStore via `Garage`, photos stored as
// files in `AppFileLocations.photosDirectory` (only the file name is persisted).
//
// Behaviour to implement:
// - `pair(rawQR:)`: `BikeQR.parse` (trim like Kotlin) → `garage.save(qr)` → select it → log
//   `qr.parsedLogLine` (NEVER the raw text) → `.paired(bike)`. Failure: log
//   `BikeQR.parseFailedLogLine(for:)`, return `.invalid(hint: BikeQR.iosFailureHint(for:) ?? "Invalid QR")`
//   (localize "Invalid QR" ES "QR no válido").
// - `pairManually`: `BikeQR.buildManual(ssid:password:displayName:)` then the same as pair.
// - `remove`: `garage.remove(id)`; delete its photo file; `SettingsStore.removeAllScopedValues(forBike:)`
//   is already done by Garage.remove (check) — do not double-delete.
// - Every mutation refreshes `bikes` / `selected` and notifies `observeSelection` handlers when the
//   selected bike changes (SettingsModel re-scopes; ConnectionModel uses it for "Connect to <name>").
//
// Implementation notes:
// - Selection handlers fire whenever the `selected` VALUE changes (another bike, or the selected
//   bike renamed / re-photographed / re-scanned), synchronously on the main actor.
// - Photos: the UI downsizes / re-encodes (Android: ≤ ~1440 px, JPEG quality 85) before calling
//   `setPhoto`; the model stores the bytes as `<bikeId>-<random>.<ext>` so every change produces a
//   new file name (the observed `bikes` value changes and SwiftUI reloads the image) and deletes
//   the previous file.

import Foundation
import Observation
import OpenCfMotoCore

@MainActor
@Observable
public final class GarageModel {
    @ObservationIgnored let core: AppCore

    /// All saved bikes (Garage order).
    public private(set) var bikes: [GarageBike] = []
    /// The bike Connect uses; nil when the garage is empty.
    public private(set) var selected: GarageBike?

    public init(core: AppCore) {
        self.core = core
        reload()
    }

    /// Re-reads the garage from storage.
    public func reload() {
        core.garage.reload()
        refresh()
    }

    /// Scanned (or imported-from-photo) QR text.
    public func pair(rawQR: String) -> PairingOutcome {
        guard let qr = BikeQR.parse(rawQR) else {
            // The failure line only carries the fixed hint text — never the scanned text, which may
            // contain a Wi-Fi password in a format the parser did not recognise.
            Log.w(Self.tagQR, BikeQR.parseFailedLogLine(for: rawQR))
            let hint = BikeQR.iosFailureHint(for: rawQR).map(strings.qrHint) ?? strings.invalidQR
            return .invalid(hint: hint)
        }
        return remember(qr, source: "QR")
    }

    /// Bikes without a QR (e.g. Benelli TRK): SSID + password typed by the rider.
    public func pairManually(ssid: String, password: String, name: String?) -> PairingOutcome {
        let trimmedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSSID.isEmpty, !password.isEmpty else {
            Log.w(Self.tagQR, "manual Wi-Fi pairing refused: SSID and password are required")
            return .invalid(hint: strings.ssidAndPasswordRequired)
        }
        guard let qr = BikeQR.buildManual(ssid: ssid, password: password, displayName: name) else {
            Log.w(Self.tagQR, "manual Wi-Fi pairing FAILED for ssid=\(trimmedSSID)")
            return .invalid(hint: strings.invalidQR)
        }
        return remember(qr, source: "manual Wi-Fi")
    }

    public func select(_ id: String) {
        guard let bike = core.garage.bike(id: id) else { return }
        core.garage.select(id)
        Log.i(Self.tagGarage, "selected \(bike.name) (ssid=\(bike.ssid))")
        refresh()
    }

    public func rename(_ id: String, to name: String) {
        guard core.garage.bike(id: id) != nil else { return }
        core.garage.rename(id, to: name)
        refresh()
    }

    /// Saves JPEG/PNG data as the bike photo (replaces the previous file).
    public func setPhoto(_ id: String, imageData: Data, fileExtension: String = "jpg") throws {
        guard let bike = core.garage.bike(id: id) else { throw LogicData.UserError(strings.bikeNotFound) }
        guard !imageData.isEmpty else { throw LogicData.UserError(strings.couldNotReadImage) }
        let directory = core.services.files.photosDirectory
        let fileName = "\(Self.safeStem(bike.id))-\(Self.randomSuffix()).\(Self.safeExtension(fileExtension))"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try imageData.write(to: directory.appendingPathComponent(fileName, isDirectory: false), options: .atomic)
        } catch {
            Log.w(Self.tagGarage, "photo save failed for \(bike.name): \(LogicData.detail(of: error))")
            throw LogicData.UserError(strings.couldNotReadImage)
        }
        let previous = bike.photoFileName
        core.garage.setPhoto(id, fileName: fileName)
        if let previous, previous != fileName { deletePhotoFile(named: previous) }
        Log.i(Self.tagGarage, "photo set for \(bike.name) (\(imageData.count) bytes)")
        refresh()
    }

    public func removePhoto(_ id: String) {
        guard let bike = core.garage.bike(id: id) else { return }
        core.garage.setPhoto(id, fileName: nil)
        if let name = bike.photoFileName { deletePhotoFile(named: name) }
        refresh()
    }

    /// File URL of the bike photo, nil when none.
    public func photoURL(for id: String) -> URL? {
        guard let name = core.garage.bike(id: id)?.photoFileName, let url = photoFileURL(named: name),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    public func remove(_ id: String) {
        // Garage.remove also deletes the raw QR secret, the bike's scoped settings (`*#<id>`) and
        // the SSID-keyed learned data when no other bike shares the SSID.
        guard let removed = core.garage.remove(id) else { return }
        if let name = removed.photoFileName { deletePhotoFile(named: name) }
        Log.i(Self.tagGarage, "removed \(removed.name) (ssid=\(removed.ssid))")
        for handler in removalHandlers { handler(removed.id) } // fuel MVP: FuelModel drops its caches
        refresh()
    }

    /// The parsed QR of a saved bike (SSID, password, model…), nil if unreadable.
    public func qr(for id: String) -> BikeQR? {
        core.garage.qr(for: id)
    }

    /// Learned dash canvas for a bike's SSID (shown in the garage detail), nil if never connected.
    public func learnedCanvas(for id: String) -> VideoCanvas? {
        guard let bike = core.garage.bike(id: id) else { return nil }
        return core.dashMemory.learnedCanvas(forSSID: bike.ssid)
    }

    // MARK: Model-to-model (internal)

    /// Called with the new selection after every change of `selected` (main actor).
    func observeSelection(_ handler: @escaping @MainActor (GarageBike?) -> Void) {
        selectionHandlers.append(handler)
    }

    @ObservationIgnored private var selectionHandlers: [@MainActor (GarageBike?) -> Void] = []

    /// ADDITION (fuel MVP): called with the id of a removed bike, after `Garage.remove` deleted its data
    /// (every `*#<id>` key, fuel included) and before the published list changes (main actor).
    func observeRemoval(_ handler: @escaping @MainActor (String) -> Void) {
        removalHandlers.append(handler)
    }

    @ObservationIgnored private var removalHandlers: [@MainActor (String) -> Void] = []

    // MARK: Private

    private static let tagQR = "QR"
    private static let tagGarage = "garage"

    private var strings: LogicData.Strings { LogicData.Strings(core.language) }

    /// Saves + selects a parsed QR and logs it without secrets.
    private func remember(_ qr: BikeQR, source: String) -> PairingOutcome {
        Log.i(Self.tagQR, qr.parsedLogLine)
        guard !qr.requiresPhoneHotspot else {
            // The dash joins the PHONE's hotspot (no SoftAP SSID / password in the QR): the iPhone app
            // cannot connect that way, so saving it would only lead to a join of a network that does
            // not exist (review IOS-3).
            Log.w(Self.tagQR, "phone-hotspot pairing QR refused: not supported on iPhone (ssid=\(qr.ssid))")
            return .invalid(hint: strings.qrHint(BikeQR.iosPhoneHotspotUnsupportedHint))
        }
        let existed = core.garage.bike(matching: qr) != nil
        let bike = core.garage.save(qr)
        Log.i(Self.tagGarage, "\(existed ? "updated" : "added") \(bike.name) from \(source) (ssid=\(bike.ssid), id=\(bike.id))")
        refresh()
        return .paired(bike)
    }

    /// Publishes the garage state; notifies the selection observers when `selected` changed.
    private func refresh() {
        let newBikes = core.garage.bikes
        let newSelected = core.garage.selected
        if newBikes != bikes { bikes = newBikes }
        guard newSelected != selected else { return }
        selected = newSelected
        for handler in selectionHandlers { handler(newSelected) }
    }

    /// The photo URL for a stored file name; nil for anything that is not a plain file name.
    private func photoFileURL(named name: String) -> URL? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { return nil }
        return core.services.files.photosDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private func deletePhotoFile(named name: String) {
        guard let url = photoFileURL(named: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// `jpg` / `png` / `heic`…: lower-cased ASCII alphanumerics (≤ 8), `jpg` when nothing is left.
    static func safeExtension(_ ext: String) -> String {
        let cleaned = String(ext.lowercased().unicodeScalars
            .filter { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }
            .prefix(8).map(Character.init))
        return cleaned.isEmpty ? "jpg" : cleaned
    }

    /// Bike ids are `b<hex>` (plus a rare `x<n>` collision suffix); keep only safe characters.
    private static func safeStem(_ id: String) -> String {
        let cleaned = String(id.unicodeScalars
            .filter { ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") }
            .map(Character.init))
        return cleaned.isEmpty ? "bike" : cleaned
    }

    private static func randomSuffix() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}
