// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the `-demoSeed` fuel data for the demo bike (the fictional 675 SR-R of DemoSeed), used by the E2E
// screenshots. Demo data only: a catalog profile, three refuels computed from it so every litre figure fits
// the tank, and the km counter. No position (no odometer anchor) is seeded.
//
// With T = tank, s = seed km/L, k = s + 1 (the "measured" km/L: inside the seed band and under the
// single-interval cap 1.15 s, so it is the effective km/L) and r = 12 %:
// - F0: full, no litres, 20 days ago, odo 4000;
// - F1: full, 9 days ago, odo 4000 + 0.8·T·k, litres 0.8·T, 4.25 per litre («~(s+1) km/L de tus cargas (1)»);
// - P: partial, 3 days ago, odo F1 + 120, litres 5; fuelP = min(T, T − 120/k + 5); rangeAtP = (fuelP − r·T)·k;
// - the counter at P + 0.3 × rangeAtP (ok) or P + rangeAtP − 60 (low: ~60 km to the reserve);
// - aged = ok with every entry 35 days older (the newest 38 days old).
// setup = no fuel data and the legacy profile hint: Home shows «¿Cuál es tu moto?».

import Foundation
import OpenCfMotoCore

public enum DemoFuel {
    public enum Mode: String, Sendable, CaseIterable { case ok, low, aged, setup }

    /// The demo bike's catalog row.
    public static let catalogId = "cfmoto-675sr-r"

    /// Seeds the demo bike's fuel data for `mode` (replacing any fuel data it had).
    public static func seed(store: KeyValueStore, garage: Garage, bikeId: String, mode: Mode, now: Date) {
        let fuel = FuelStore(store: store)
        fuel.removeAll(bikeId: bikeId)
        garage.setProfileHint(bikeId, .legacy)
        guard mode != .setup else { return }
        let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let profile = demoProfile(entry: FuelCatalog.entry(id: catalogId), nowMs: nowMs)
        let docs = documents(profile: profile, mode: mode, nowMs: nowMs)
        fuel.setProfile(profile, bikeId: bikeId)
        fuel.setLog(docs.log, bikeId: bikeId)
        fuel.setOdometer(docs.odometer, bikeId: bikeId)
    }

    /// The catalog row's profile, or a hand-entered 15 L / 19 km/L one when the row is missing.
    static func demoProfile(entry: FuelCatalogEntry?, nowMs: Int64) -> FuelProfile {
        if let entry { return FuelProfile.from(entry, nowMs: nowMs) }
        return FuelProfile(catalogId: nil, name: "", tankL: 15, seedKmPerL: 19, seedSource: .manual, updatedAtMs: nowMs)
    }

    /// The refuel log and the counter for a profile and a mode (not `.setup`).
    static func documents(profile: FuelProfile, mode: Mode, nowMs: Int64) -> (log: RefuelLog, odometer: FuelOdometerState) {
        let t = profile.tankL, s = profile.seedKmPerL
        let k = s + 1
        let r = Double(profile.reservePct) / 100
        let day = RangeEstimator.msPerDay
        let shift: Int64 = mode == .aged ? 35 * day : 0
        let f0Odo = 4000.0
        let f1Odo = f0Odo + 0.8 * t * k
        let pOdo = f1Odo + 120
        let fuelP = min(t, t - 120 / k + 5)
        let rangeAtP = (fuelP - r * t) * k
        let sinceP = mode == .low ? rangeAtP - 60 : 0.3 * rangeAtP
        let log = RefuelLog(entries: [
            RefuelEntry(id: "demo-f0", atMs: nowMs - 20 * day - shift, kind: .full, odometerKm: f0Odo),
            RefuelEntry(id: "demo-f1", atMs: nowMs - 9 * day - shift, kind: .full, litres: 0.8 * t, pricePerLitre: 4.25,
                        odometerKm: f1Odo),
            RefuelEntry(id: "demo-p", atMs: nowMs - 3 * day - shift, kind: .partial, litres: 5, odometerKm: pOdo),
        ])
        var odometer = FuelOdometerState()
        odometer.totalKm = pOdo + sinceP
        return (log, odometer)
    }
}
