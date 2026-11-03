// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 field checklist (docs/PRUEBA-EN-LA-MOTO.md, steps 5-9): what the owner shares
// after each condition must still be there.
// - The dash video recording the Logs screen offers survives the 2-min export purge at every
//   `.background` (the lock of the next condition), until a new recording replaces it; the next launch
//   still clears it.
// - The toggle turns off once the recorder closed the file by itself (600 access units), so the Logs
//   screen offers the file and one tap starts the next condition's recording.
// - After a launch that found the unclean-background marker (L16), that run's saves keep the restored
//   log, so one share after a second kill still has the first killed run; a normal relaunch still
//   consumes the old log; the session file keeps its 256 KiB cap.
// NOTE (Linux): main-actor tests must be `async` (swift-corelibs-xctest).

import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class LockChecklistShareTests: XCTestCase {
    private let markerKey = "ios.bg_session_marker"
    private static let wallStart = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        LogRedactor.install(on: .shared, includeSecrets: false)
        super.tearDown()
    }

    @MainActor private func lock(_ h: AppTestHarness) {
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.background)
    }

    @MainActor private func unlock(_ h: AppTestHarness) {
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The engine's recorder writes the file as access units go out: its modification date is the last
    /// access unit written.
    private func write(_ url: URL, lastFrameSecondsAgo age: TimeInterval) throws {
        try Data(repeating: 0, count: 4096).write(to: url)
        try setAge(url, age)
    }

    private func setAge(_ url: URL, _ age: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    /// Files and stores that outlive an AppModel, like a real app's container across launches.
    private struct Container {
        let files: AppFileLocations
        let keyValueStore = InMemoryKeyValueStore()
        let secretStore = InMemorySecretStore()
    }

    private func makeContainer() throws -> Container {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ocm-checklist-\(UUID().uuidString)", isDirectory: true)
        let files = AppFileLocations(tripsDirectory: root.appendingPathComponent("trips", isDirectory: true),
                                     photosDirectory: root.appendingPathComponent("photos", isDirectory: true),
                                     exportsDirectory: root.appendingPathComponent("exports", isDirectory: true))
        for dir in [files.tripsDirectory, files.photosDirectory, files.exportsDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Container(files: files)
    }

    /// A new process on `container`: the log ring starts empty, then AppModel.start() (hydrate, L16, the
    /// launch purge). The 30-s saver is pushed out of the test: an earlier run's model stays alive here,
    /// where a killed process would have stopped writing.
    @MainActor
    private func launch(_ container: Container, wall: Locked<Date>? = nil) -> AppTestHarness {
        Log.shared.clear()
        let h = AppTestHarness { services in
            services.files = container.files
            services.keyValueStore = container.keyValueStore
            services.secretStore = container.secretStore
            if let wall { services.now = { wall.current } }
        }
        h.model.sessionLogInterval = 3_600
        h.model.start()
        return h
    }

    // MARK: The recording the Logs screen offers

    @MainActor
    func testTheBackgroundPurgeKeepsTheRecordingTheLogsScreenOffers() async throws {
        let container = try makeContainer()
        let wall = Locked(Self.wallStart)
        let h = launch(container, wall: wall)
        defer { h.connection.stop() }
        let exports = container.files.exportsDirectory
        h.addBike()
        h.connection.connect()
        XCTAssertTrue(h.connection.isSessionActive)

        // Condition A: record, lock, unlock. The recorder's last access unit went out long before the
        // unlock (hold answers about 1.1 pulls a second: the 600th lands 7 to 10 min into the lock).
        h.ride.setDashVideoRecording(true)
        let recordingA = try XCTUnwrap(h.ride.dashVideoRecordingURL)
        try write(recordingA, lastFrameSecondsAgo: 0)
        lock(h)
        try setAge(recordingA, LogicData.backgroundExportAge + 60)
        unlock(h)
        h.ride.setDashVideoRecording(false)
        XCTAssertEqual(h.ride.dashVideoRecordingURL, recordingA, "offered by the Logs screen")

        // The owner locks again before sharing (or shares and locks for the next condition): the offered
        // recording stays; other old exports still go.
        let oldLog = exports.appendingPathComponent("opencfmoto-log-20270115-130000.txt")
        try Data("log".utf8).write(to: oldLog)
        try setAge(oldLog, LogicData.backgroundExportAge + 60)
        lock(h)
        XCTAssertTrue(exists(recordingA), "the recording the Logs screen offers survives the lock")
        XCTAssertFalse(exists(oldLog), "other share exports are still purged at the lock")
        unlock(h)

        // Condition B: a new recording replaces it, so A is no longer offered and goes at the next lock.
        wall.set(Self.wallStart.addingTimeInterval(600))
        h.ride.setDashVideoRecording(true)
        let recordingB = try XCTUnwrap(h.ride.dashVideoRecordingURL)
        XCTAssertNotEqual(recordingB, recordingA)
        try write(recordingB, lastFrameSecondsAgo: 0)
        lock(h)
        XCTAssertFalse(exists(recordingA), "no longer offered: purged with the other old exports")
        XCTAssertTrue(exists(recordingB))
        try setAge(recordingB, LogicData.backgroundExportAge + 60)
        unlock(h)
        lock(h)
        XCTAssertTrue(exists(recordingB), "still the one the Logs screen offers")
        unlock(h)

        // The next launch clears it with every other export.
        let next = launch(container)
        XCTAssertFalse(exists(recordingB), "cleared at launch")
        XCTAssertNil(next.ride.dashVideoRecordingURL)
    }

    // MARK: The toggle follows a recorder that closed its file

    @MainActor
    func testTheToggleTurnsOffWhenTheRecorderClosesTheFileByItself() async throws {
        let h = AppTestHarness()
        defer { h.connection.stop() }
        h.addBike()
        h.connection.connect()
        let log = LogCapture()
        defer { log.stop() }
        h.ride.setDashVideoRecording(true)
        let url = try XCTUnwrap(h.ride.dashVideoRecordingURL)
        h.ride.runHousekeeping()
        XCTAssertTrue(h.ride.isRecordingDashVideo, "still recording")
        XCTAssertTrue(h.projection.isWireDumping)

        h.projection.finishWireDump() // the 600th access unit
        XCTAssertTrue(h.projection.isWireDumpFinished)
        h.ride.runHousekeeping()
        XCTAssertFalse(h.ride.isRecordingDashVideo, "the toggle follows the closed file")
        XCTAssertEqual(h.ride.dashVideoRecordingURL, url, "and the Logs screen offers it")
        XCTAssertFalse(h.projection.isWireDumpFinished, "the recorder's slot is released")
        XCTAssertEqual(log.messages(tag: "RIDE").filter { $0.hasPrefix("dash video recording ended") },
                       ["dash video recording ended (\(url.lastPathComponent)): the recorder closed the file"])

        // The next condition: one tap starts a new recording.
        h.ride.setDashVideoRecording(true)
        XCTAssertTrue(h.ride.isRecordingDashVideo)
        XCTAssertEqual(h.projection.wireDumps.count, 2)
        XCTAssertTrue(h.projection.isWireDumping)
        h.ride.runHousekeeping()
        XCTAssertTrue(h.ride.isRecordingDashVideo, "a recorder still writing keeps the toggle on")
    }

    @MainActor
    func testARecordingThatFilledUpWhileLockedIsOffAtTheUnlock() async throws {
        let h = AppTestHarness()
        defer { h.connection.stop() }
        h.addBike()
        h.connection.connect()
        h.ride.setDashVideoRecording(true)
        lock(h)
        h.projection.finishWireDump()
        h.model.scenePhaseChanged(.inactive)
        XCTAssertTrue(h.ride.isRecordingDashVideo, "not yet: the unlock is not done")
        h.model.scenePhaseChanged(.active)
        XCTAssertFalse(h.ride.isRecordingDashVideo, "off as soon as the app is back, before a housekeeping tick")
        XCTAssertNotNil(h.ride.dashVideoRecordingURL)
    }

    @MainActor
    func testAMirrorRecordingFollowsTheMirrorRecorder() async throws {
        let h = AppTestHarness()
        defer { h.connection.stop() }
        let mirror = try XCTUnwrap(h.mirror as? PreviewMirror)
        h.addBike()
        h.connection.startMirror()
        XCTAssertEqual(h.connection.mode, .mirror)
        h.ride.setDashVideoRecording(true)
        XCTAssertTrue(mirror.isWireDumping)
        XCTAssertFalse(h.projection.isWireDumping)

        // The own-UI recorder is not the source: its state does not matter.
        try h.projection.startWireDump(to: h.core.services.files.exportsDirectory.appendingPathComponent("other.h264"),
                                       maxFrames: 1)
        h.projection.finishWireDump()
        h.ride.runHousekeeping()
        XCTAssertTrue(h.ride.isRecordingDashVideo, "the mirror relay is still recording")

        mirror.finishWireDump()
        h.ride.runHousekeeping()
        XCTAssertFalse(h.ride.isRecordingDashVideo)
        XCTAssertFalse(mirror.isWireDumpFinished, "the relay's slot is released")
    }

    // MARK: One share covers two kills

    @MainActor
    func testASecondKillKeepsTheFirstKilledRunInTheSavedLog() async throws {
        let container = try makeContainer()
        var runs: [AppTestHarness] = []
        defer { for h in runs { h.connection.stop() } }

        // Run 1, condition A: a session, locked; the background save; iOS kills the app.
        let r1 = launch(container)
        runs.append(r1)
        r1.addBike()
        r1.connection.connect()
        XCTAssertTrue(r1.connection.isSessionActive)
        lock(r1)
        Log.i("VIDEO", "[bg] +6m10s mode=hold enc=hold out=0.0fps pulls=1.0/s RUN-A")
        Log.i("APP", "[lock] 6m12s locked link=streaming wifi=up RUN-A")
        r1.model.logs.persistSession() // the 30-s saver
        XCTAssertNotNil(container.keyValueStore.double(forKey: markerKey), "killed while locked in a session")

        // Run 2, condition B: L16, run A restored; run B's saves keep it in front of B's lines.
        let r2 = launch(container)
        runs.append(r2)
        XCTAssertTrue(LDTest.sharedLogMessages().contains { $0.hasPrefix("previous run ended in the background") })
        XCTAssertTrue(r2.model.logs.carriesRestoredSession)
        XCTAssertEqual(r2.model.logs.restoredSession?.contains("RUN-A"), true)
        r2.addBike()
        r2.connection.connect()
        lock(r2)
        Log.i("VIDEO", "[bg] +3m00s mode=hold enc=hold out=0.0fps pulls=1.0/s RUN-B")
        r2.model.logs.persistSession()
        let savedB = try String(contentsOf: r2.model.logs.sessionFiles.sessionURL, encoding: .utf8)
        let a = try XCTUnwrap(savedB.range(of: "RUN-A"), "run B's save keeps run A")
        let b = try XCTUnwrap(savedB.range(of: "RUN-B"))
        XCTAssertLessThan(a.lowerBound, b.lowerBound, "oldest first")
        XCTAssertTrue(savedB.contains("previous run ended in the background"), "run B's L16 marks where B starts")
        XCTAssertFalse(savedB.contains(SessionLogFiles.restoredBanner), "no banner in the file: nothing nests")
        // The asynchronous 30-s save carries it too.
        Log.i("APP", "[lock] 3m30s locked link=streaming wifi=up RUN-B2")
        r2.model.logs.persistSession(synchronously: false)
        let url = r2.model.logs.sessionFiles.sessionURL
        let carried = await eventually {
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("RUN-B2")
        }
        XCTAssertTrue(carried)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("RUN-A"))

        // Run 3: the owner shares once, at the end. Both killed runs are there, under one banner.
        let r3 = launch(container)
        runs.append(r3)
        let shared = try String(contentsOf: try r3.model.logs.exportLogs().url, encoding: .utf8)
        XCTAssertTrue(shared.contains("RUN-A"), "the first killed run survives the second kill")
        XCTAssertTrue(shared.contains("RUN-B2"))
        XCTAssertEqual(shared.components(separatedBy: SessionLogFiles.restoredBanner).count, 2, "one restored banner")
    }

    @MainActor
    func testANormalRelaunchStillConsumesTheOldLog() async throws {
        let container = try makeContainer()
        var runs: [AppTestHarness] = []
        defer { for h in runs { h.connection.stop() } }

        // Run 1 leaves the foreground with no session (no marker): saved, then the app ends normally.
        let r1 = launch(container)
        runs.append(r1)
        Log.i("TEST", "RUN-X")
        lock(r1)
        XCTAssertNil(container.keyValueStore.double(forKey: markerKey))

        // Run 2: X is shown and shared once, but not carried into run 2's saves.
        let r2 = launch(container)
        runs.append(r2)
        XCTAssertFalse(r2.model.logs.carriesRestoredSession)
        XCTAssertEqual(r2.model.logs.restoredSession?.contains("RUN-X"), true)
        Log.i("TEST", "RUN-Y")
        r2.model.logs.persistSession()
        let saved = try String(contentsOf: r2.model.logs.sessionFiles.sessionURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("RUN-Y"))
        XCTAssertFalse(saved.contains("RUN-X"), "a normal relaunch consumes the old log")

        // A session that came back to the foreground before the kill leaves no marker either.
        r2.addBike()
        r2.connection.connect()
        lock(r2)
        unlock(r2)
        Log.i("TEST", "RUN-Z")
        r2.model.logs.persistSession()

        let r3 = launch(container)
        runs.append(r3)
        XCTAssertFalse(r3.model.logs.carriesRestoredSession)
        let shared = try String(contentsOf: try r3.model.logs.exportLogs().url, encoding: .utf8)
        XCTAssertTrue(shared.contains("RUN-Z"))
        XCTAssertFalse(shared.contains("RUN-X"))
    }

    @MainActor
    func testTheCarriedLogKeepsTheSessionFileCap() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // The previous runs' log is already at the cap.
        let filler = String(repeating: "x", count: 90)
        let old = (0 ..< 3_000).map { "12:00:00.000 I/OLD: old line \($0) \(filler)" }.joined(separator: "\n")
        XCTAssertGreaterThan(old.utf8.count, SessionLogFiles.maxSessionBytes)
        try SessionLogFiles(directory: SessionLogFiles.directory(for: env.services.files)).writeSession(old)

        let log = Log()
        let model = LogsModel(core: env.core, log: log)
        model.timeZone = utc
        model.hydrate()
        model.carriesRestoredSession = true
        for i in 0 ..< 200 { log.log(.info, "NEW", "line \(i)") }
        model.persistSession()
        let saved = try String(contentsOf: model.sessionFiles.sessionURL, encoding: .utf8)
        XCTAssertLessThanOrEqual(saved.utf8.count, SessionLogFiles.maxSessionBytes)
        XCTAssertTrue(saved.hasSuffix("I/NEW: line 199"), "the newest line is kept")
        XCTAssertTrue(saved.contains("I/NEW: line 0\n"), "all of this run's lines fit")
        XCTAssertTrue(saved.contains("old line 2999 "), "then the newest of the carried lines")
        XCTAssertFalse(saved.contains("old line 0 "), "the oldest carried lines go")
        XCTAssertTrue(saved.hasPrefix("12:00:00.000 I/OLD: old line "), "cut at a line start")

        // The helper: no carried log is the plain snapshot; trailing newlines of the carried log go.
        let lines = log.lines()
        XCTAssertEqual(SessionLogFiles.sessionText(lines, carrying: nil, timeZone: utc),
                       SessionLogFiles.snapshot(lines, timeZone: utc))
        XCTAssertEqual(SessionLogFiles.sessionText(lines, carrying: "\n", timeZone: utc),
                       SessionLogFiles.snapshot(lines, timeZone: utc))
        XCTAssertEqual(SessionLogFiles.sessionText([], carrying: "a\nb\n\n", timeZone: utc), "a\nb")
        XCTAssertEqual(SessionLogFiles.sessionText(Array(lines.suffix(1)), carrying: "a", timeZone: utc),
                       "a\n" + SessionLogFiles.snapshot(Array(lines.suffix(1)), timeZone: utc))
    }
}
