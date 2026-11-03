// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (contract §7): the exact text of the app-side lines L14–L18
// (`LockDiagnostics`), including the MetricKit lines the iOS CrashReporter logs (L18), so every
// rendering is pinned on Linux.

import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class LockDiagnosticsTests: XCTestCase {
    // MARK: L14

    func testSessionContexts() {
        XCTAssertEqual(LockDiagnostics.sessionContext(isSessionActive: true, mode: .dashUI, phase: .streaming),
                       "own UI session, streaming")
        XCTAssertEqual(LockDiagnostics.sessionContext(isSessionActive: true, mode: .dashUI, phase: .waitingForBike),
                       "own UI session, waitingForBike")
        XCTAssertEqual(LockDiagnostics.sessionContext(isSessionActive: true, mode: .mirror, phase: .mirroring),
                       "mirror session, mirroring")
        XCTAssertEqual(LockDiagnostics.sessionContext(isSessionActive: false, mode: .none, phase: .idle), "no session")
        XCTAssertEqual(LockDiagnostics.sessionContext(isSessionActive: false, mode: .dashUI, phase: .stopped), "no session")
        XCTAssertEqual(LockDiagnostics.sessionContext(isSessionActive: true, mode: .none, phase: .error), "no session")
    }

    func testSceneChangeLines() {
        let ctx = "own UI session, streaming"
        XCTAssertEqual(LockDiagnostics.sceneChange(from: .active, to: .inactive, backgroundSeconds: nil, context: ctx),
                       "scene active \u{2192} inactive (own UI session, streaming)")
        XCTAssertEqual(LockDiagnostics.sceneChange(from: .inactive, to: .background, backgroundSeconds: nil, context: ctx),
                       "scene inactive \u{2192} background (own UI session, streaming)")
        XCTAssertEqual(LockDiagnostics.sceneChange(from: .background, to: .inactive, backgroundSeconds: 723, context: ctx),
                       "scene background \u{2192} inactive after 12m03s (own UI session, streaming)")
        XCTAssertEqual(LockDiagnostics.sceneChange(from: .background, to: .active, backgroundSeconds: 3_723, context: "no session"),
                       "scene background \u{2192} active after 1h02m03s (no session)")
        XCTAssertEqual(LockDiagnostics.sceneChange(from: .inactive, to: .active, backgroundSeconds: 99, context: ctx),
                       "scene inactive \u{2192} active (own UI session, streaming)", "only leaving .background says how long")
        XCTAssertEqual(LockDiagnostics.sceneChange(from: .background, to: .inactive, backgroundSeconds: nil, context: ctx),
                       "scene background \u{2192} inactive (own UI session, streaming)")
    }

    // MARK: L15

    private func status(_ projection: ProjectionStatsSummary, locked: TimeInterval = 300, link: ConnectionPhase = .streaming,
                        lost: Bool = false, gps: TimeInterval? = 1, heading: TimeInterval? = 2,
                        battery: BatteryStatus? = BatteryStatus(level: 0.63, state: .charging),
                        thermal: ThermalLevel = .none, lowPower: Bool = false) -> LockDiagnostics.LockStatus {
        LockDiagnostics.LockStatus(lockedSeconds: locked, link: link, bikeWifiLost: lost, projection: projection,
                                   gpsAgeSeconds: gps, headingAgeSeconds: heading, battery: battery, thermal: thermal,
                                   lowPowerMode: lowPower)
    }

    func testLockStatusLineOfTheContract() {
        let p = ProjectionStatsSummary(mode: "background-software", framesPerSecond: 5.2, encoder: "vt-sw", pullRate: 5.1)
        XCTAssertEqual(LockDiagnostics.lockStatus(status(p)),
                       "[lock] 5m00s locked link=streaming wifi=up pulls=5.1/s dash=backgroundSoftware vt-sw 5.2fps gps=1s "
                           + "heading=2s batt=63% charging thermal=none lowPower=false")
    }

    func testLockStatusVariants() {
        let hold = ProjectionStatsSummary(mode: "hold", framesPerSecond: 0, encoder: "hold", pullRate: 1.04)
        XCTAssertEqual(LockDiagnostics.lockStatus(status(hold, locked: 59.6, link: .reconnecting, lost: true, gps: nil, heading: nil,
                                                         battery: nil, thermal: .critical, lowPower: true)),
                       "[lock] 1m00s locked link=reconnecting wifi=down pulls=1.0/s dash=hold hold 0.0fps gps=- heading=- "
                           + "batt=- thermal=critical lowPower=true")
        let unknown = ProjectionStatsSummary(mode: "stopped", framesPerSecond: .nan, encoder: nil, pullRate: .infinity)
        XCTAssertEqual(LockDiagnostics.lockStatus(status(unknown, locked: -4, link: .waitingForBike, lost: true, gps: -3,
                                                         heading: 4_000, battery: BatteryStatus(level: nil, state: .unknown))),
                       "[lock] 0s locked link=waitingForBike wifi=down pulls=?/s dash=stopped - ?fps gps=0s heading=1h06m40s "
                           + "batt=?% unknown thermal=none lowPower=false")
        let cpu = ProjectionStatsSummary(mode: "background-software", framesPerSecond: 7.96, encoder: "cpu-minih264", pullRate: 7.96)
        XCTAssertEqual(LockDiagnostics.lockStatus(status(cpu, battery: BatteryStatus(level: 1, state: .full), thermal: .moderate)),
                       "[lock] 5m00s locked link=streaming wifi=up pulls=8.0/s dash=backgroundSoftware cpu-minih264 8.0fps gps=1s "
                           + "heading=2s batt=100% full thermal=moderate lowPower=false")
    }

    func testDashModeNames() {
        XCTAssertEqual(LockDiagnostics.dashMode("background-software"), "backgroundSoftware")
        for m in ["idle", "foreground", "hold", "stopped", "mirror"] { XCTAssertEqual(LockDiagnostics.dashMode(m), m) }
    }

    func testNoLockLineCarriesARedactedKeyOrCoordinates() {
        let p = ProjectionStatsSummary(mode: "background-software", framesPerSecond: 5.2, encoder: "vt-sw", pullRate: 5.1)
        let line = LockDiagnostics.lockStatus(status(p))
        for key in ["sn=", "key=", "token=", "pwd=", "ssid", "lat", "lon"] { XCTAssertFalse(line.contains(key), key) }
        XCTAssertEqual(LogRedactor.redactAll(line), line, "the redactor leaves the line alone")
    }

    // MARK: L16, L17

    func testUncleanBackgroundExitLine() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(LockDiagnostics.uncleanBackgroundExit(backgroundedAt: Date(timeIntervalSince1970: 1_800_021_792), timeZone: utc),
                       "previous run ended in the background during a dash session (backgrounded 14:03:12): "
                           + "iOS stopped the app, or it was swiped away")
        XCTAssertEqual(LockDiagnostics.uncleanBackgroundExit(backgroundedAt: Date(timeIntervalSince1970: 1_800_000_005.9), timeZone: utc),
                       "previous run ended in the background during a dash session (backgrounded 08:00:05): "
                           + "iOS stopped the app, or it was swiped away")
    }

    func testGPSRestartLine() {
        XCTAssertEqual(LockDiagnostics.gpsRestartedForBackground,
                       "GPS restarted with background updates (it was running for the preview)")
    }

    func testKeys() {
        XCTAssertEqual(LockDiagnostics.backgroundSessionMarkerKey, "ios.bg_session_marker")
        XCTAssertEqual(LockDiagnostics.lockedStreamPolicyKey, "ios.locked_stream_policy")
    }

    // MARK: L18 (MetricKit, logged by the iOS CrashReporter)

    func testMetricKitDiagnosticLines() {
        XCTAssertEqual(LockDiagnostics.cpuException(cpuSeconds: 54.2, sampledSeconds: 60, build: "12", osVersion: "iPhone OS 27.0.1 (25A362)"),
                       "[metrickit] CPU exception: 54s CPU in 60s (build 12, iOS 27.0.1)")
        XCTAssertEqual(LockDiagnostics.hang(seconds: 3.24, build: "12", osVersion: "iPhone OS 27.0.1 (25A362)"),
                       "[metrickit] hang: 3.2s (build 12, iOS 27.0.1)")
        XCTAssertEqual(LockDiagnostics.diskWrites(megabytes: 1024.3, build: "12", osVersion: "iPhone OS 27.0.1 (25A362)"),
                       "[metrickit] disk writes: 1024 MB (build 12, iOS 27.0.1)")
        XCTAssertEqual(LockDiagnostics.cpuException(cpuSeconds: .nan, sampledSeconds: 180, build: " ", osVersion: ""),
                       "[metrickit] CPU exception: ?s CPU in 180s (build ?, iOS ?)")
    }

    func testMetricKitBackgroundExitsLine() {
        let e = LockDiagnostics.BackgroundExits(cpuLimit: 1, memory: 0, memoryPressure: 0, watchdog: 0, lockedFile: 0,
                                                taskTimeout: 0, abnormal: 0, normal: 3)
        XCTAssertEqual(LockDiagnostics.backgroundExits(e),
                       "[metrickit] background exits (24h): cpu-limit=1 memory=0 memory-pressure=0 watchdog=0 locked-file=0 "
                           + "task-timeout=0 abnormal=0 normal=3")
        XCTAssertEqual(LockDiagnostics.backgroundExits(.init(memory: 2, memoryPressure: 3, watchdog: 4, lockedFile: 5, taskTimeout: 6,
                                                             abnormal: 7, normal: 8)),
                       "[metrickit] background exits (24h): cpu-limit=0 memory=2 memory-pressure=3 watchdog=4 locked-file=5 "
                           + "task-timeout=6 abnormal=7 normal=8")
    }

    func testMetricKitOSText() {
        XCTAssertEqual(LockDiagnostics.osText("iPhone OS 27.0.1 (25A362)"), "iOS 27.0.1")
        XCTAssertEqual(LockDiagnostics.osText("iPhone OS 17.4"), "iOS 17.4")
        XCTAssertEqual(LockDiagnostics.osText("  iOS 26.1 (23B85) "), "iOS 26.1")
        XCTAssertEqual(LockDiagnostics.osText("macOS 27.0"), "macOS 27.0")
        XCTAssertEqual(LockDiagnostics.osText(""), "iOS ?")
    }
}
