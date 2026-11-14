// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP test harness: an AppModel on the preview services with a seeded legacy-QR bike, a wall clock the
// test advances (`services.now`, set BEFORE the AppModel exists), and helpers for countable sessions, fixes
// along a straight northbound track and a projecting own-UI session.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

enum FuelFix {
    static let baseLat = 4.6
    static let baseLon = -74.08
    static let mPerDegLat = 110_574.0

    /// A northbound track: `count` fixes every `everyMs`, `metresPerFix` apart, starting `startNorth` m north
    /// of the base at `start` (epoch ms).
    static func track(start: Int64, startNorth: Double = 0, metresPerFix: Double, everyMs: Int64, count: Int,
                      accuracy: Double = 5, speed: Double? = nil) -> [LocationFix] {
        (0 ..< count).map { i in
            let s = speed ?? metresPerFix / (Double(everyMs) / 1000)
            return at(start + Int64(i) * everyMs, north: startNorth + Double(i) * metresPerFix, speed: s, accuracy: accuracy)
        }
    }

    static func at(_ timeMs: Int64, north: Double, speed: Double? = 10, accuracy: Double = 5) -> LocationFix {
        LocationFix(lat: baseLat + north / mPerDegLat, lon: baseLon, speedMps: speed, accuracyM: accuracy, timeMs: timeMs)
    }

    /// The counted distance of a track (same geodesy as the counter), km.
    static func km(_ fixes: [LocationFix]) -> Double {
        zip(fixes, fixes.dropFirst()).reduce(0) { $0 + Double(TripGeodesy.androidDistance(lat1: $1.0.lat, lon1: $1.0.lon,
                                                                                            lat2: $1.1.lat, lon2: $1.1.lon)) } / 1000
    }
}

/// Real monotonic time plus a manual offset: timers keep running, tests can jump ahead (toast expiry, the
/// 60 s deferral).
final class FuelTestClock: MonotonicClock, @unchecked Sendable {
    let offset = Locked<TimeInterval>(0)
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime + offset.current }
    func jump(_ seconds: TimeInterval) { offset.withLock { $0 += seconds } }
}

@MainActor
final class FuelTestEnv {
    static let start = Date(timeIntervalSince1970: 1_793_000_000)

    let h: AppTestHarness
    let wall: Locked<Date>
    let kv: KeyValueStore
    let secrets: SecretStore
    let clock = FuelTestClock()
    private(set) var bike: GarageBike!
    var countable = true
    var sessionBike: String?

    var model: AppModel { h.model }
    var fuel: FuelModel { h.model.fuel }
    var ride: RideModel { h.model.ride }
    var core: AppCore { h.model.core }
    var nowMs: Int64 { Int64((wall.current.timeIntervalSince1970 * 1000).rounded()) }

    /// - Parameters:
    ///   - kv / secrets: reuse the stores of an earlier env (a relaunch).
    ///   - seedBike: save + select the legacy-QR test bike.
    init(kv: KeyValueStore? = nil, secrets: SecretStore? = nil, wall: Locked<Date>? = nil, seedBike: Bool = true,
         network: NetworkProvider? = nil, frameSource: VideoFrameSource? = nil,
         configure: (inout AppServices) -> Void = { _ in }) {
        let wall = wall ?? Locked(Self.start)
        let kv = kv ?? InMemoryKeyValueStore()
        let secrets = secrets ?? InMemorySecretStore()
        self.wall = wall
        self.kv = kv
        self.secrets = secrets
        let clock = self.clock
        h = AppTestHarness(network: network, frameSource: frameSource) { s in
            s.now = { wall.current }
            s.clock = clock
            s.keyValueStore = kv
            s.secretStore = secrets
            configure(&s)
        }
        if seedBike {
            bike = core.garage.bike(matching: BikeQR.parse(AppTestHarness.sampleRaw)!) ?? h.addBike().bike
            core.garage.select(bike.id)
            model.garage.reload()
        }
        // Phone entry allowed unless a test says otherwise (the moving-lock tests use the ride's fix).
        fuel.lastFixProvider = { nil }
        fuel.undoWindow = 0.3
        fuel.blindAfter = 0.05
    }

    /// Adds a second bike (another SSID) and returns it (the selection is restored).
    func addOtherBike(ssid: String = "CFMOTO-b0b0b0", modelId: String = "37416") -> GarageBike {
        let raw = "http://www.carbit.com.cn/downsdk/1/2/_sdk?modelid=\(modelId)&sn=x\(ssid.count)&action=1&ssid=\(ssid)&pwd=demo1234&auth=wpa2-psk"
        let selected = core.garage.selected?.id
        let other = core.garage.save(BikeQR.parse(raw)!)
        if let selected { core.garage.select(selected) }
        model.garage.reload()
        return other
    }

    func advance(_ seconds: TimeInterval) {
        wall.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    /// A countable session for `bikeId` (default: the test bike), driven through FuelModel's providers.
    func startCountable(_ bikeId: String? = nil) {
        sessionBike = bikeId ?? bike.id
        countable = true
        fuel.sessionBikeProvider = { [unowned self] in self.sessionBike }
        fuel.isCountableProvider = { [unowned self] in self.countable }
        fuel.sessionChanged(active: true)
        fuel.countableChanged(true)
    }

    func setCountable(_ on: Bool) {
        countable = on
        fuel.countableChanged(on)
    }

    func endSession() {
        countable = false
        let id = sessionBike
        sessionBike = nil
        fuel.countableChanged(false)
        fuel.sessionChanged(active: false)
        _ = id
    }

    /// Feeds fixes through the real location fake (RideModel → FuelModel), advancing the wall clock to each.
    func emit(_ fixes: [LocationFix]) {
        for f in fixes {
            let t = Date(timeIntervalSince1970: Double(f.timeMs) / 1000)
            if t > wall.current { wall.set(t) }
            h.location.emit(f)
        }
    }

    /// A ride of `km` kilometres north from `north` at 20 m/s, one fix every `everyMs` (≤ 5 s), starting now.
    @discardableResult
    func rideKm(_ km: Double, fromNorth north: Double = 0, everyMs: Int64 = 1000) -> [LocationFix] {
        let step = 20 * Double(everyMs) / 1000
        let n = Int((km * 1000 / step).rounded()) + 1
        let fixes = FuelFix.track(start: nowMs + 1000, startNorth: north, metresPerFix: step, everyMs: everyMs, count: n, speed: 20)
        emit(fixes)
        return fixes
    }

    /// Saves the 450MT profile and a full refuel for the test bike (canLogNow is true by default).
    func setUp450MT(_ bikeId: String? = nil, refuel: Bool = true) {
        let id = bikeId ?? bike.id
        XCTAssertEqual(fuel.saveProfile(fuel.draft(from: FuelCatalog.entry(id: "cfmoto-450mt")!), for: id), .saved)
        if refuel {
            guard case .logged = fuel.logRefuel(RefuelInput(kind: .full), for: id) else { return XCTFail("refuel refused") }
        }
    }

    /// The test bike's stored odometer document, if any.
    func storedOdometer(_ bikeId: String? = nil) -> FuelOdometerState? {
        guard let data = kv.data(forKey: "fuel_odo_v1#\(bikeId ?? bike.id)") else { return nil }
        return try? JSONDecoder().decode(FuelOdometerState.self, from: data)
    }

    /// An own-UI session projecting to the dash and streaming (RideModel's toast channel open).
    func projectOwnUI() {
        ride.sessionChanged(active: true, mirror: false)
        ride.linkPhaseChanged(.streaming)
        ride.projectionChanged(active: true)
    }

    /// Log lines of the `fuel` and `RIDE` tags while `body` runs.
    static func captureLog(_ body: () async -> Void) async -> [String] {
        let lines = Locked<[String]>([])
        let sub = Log.shared.subscribe { line in lines.withLock { $0.append("\(line.tag): \(line.message)") } }
        await body()
        Log.shared.unsubscribe(sub)
        return lines.current
    }
}

/// The CFDL16 handshake of the scripted fake dash up to streaming (ConnectionReviewFixTests' sequence):
/// CLIENT_INFO (legacy), REQ 16 (800×386) + 112, three frame pulls. Returns the closers.
func fuelStreamFromFakeDash(_ dash: LinkFakeDash) async throws -> [() -> Void] {
    let ctrl = try dash.openControl()
    try await ctrl.send(PxcFrame(cmd: 0x10000))
    _ = try await ctrl.nextRaw()
    try await ctrl.send(cmd: 0x10010, json: LinkDashSamples.cfdl16ClientInfo)
    _ = try await ctrl.next()
    let mctl = try dash.openMedia(port: 10921)
    try await mctl.send(cmd: 16, body: LinkDashSamples.configCaptureBody(width: 800, height: 386))
    _ = try await mctl.reply()
    try await mctl.send(cmd: 112)
    _ = try await mctl.reply()
    let mdata = try dash.openMedia(port: 10920)
    for _ in 1 ... 3 {
        try await mdata.send(cmd: 114)
        _ = try await mdata.frame()
    }
    return [ctrl.close, mctl.close, mdata.close]
}

extension FuelEstimate {
    var kmValue: Double? {
        switch state {
        case let .ok(k), let .low(k): return k
        default: return nil
        }
    }
}
