// SPDX-License-Identifier: AGPL-3.0-or-later
// Session log persistence and crash capture (docs/spec/app-features.md §6.4 iOS, §13.10 — review
// SPEC:CL-6): the redacted ring tail goes to last_session.log on background / while linked, the next
// launch consumes it and shows / shares it first under the Android banner; a crash report handed over
// by the app (MetricKit) is kept in last_crash.txt until dismissed.

import Foundation
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoAppModel

final class SessionLogPersistenceTests: XCTestCase {
    override func tearDown() {
        LogRedactor.install(on: .shared, includeSecrets: false)
        super.tearDown()
    }

    @MainActor
    private func makeModel(_ env: LDTestEnv) -> (LogsModel, Log) {
        let log = Log()
        let model = LogsModel(core: env.core, log: log)
        model.throttleInterval = 0.01
        model.timeZone = TimeZone(identifier: "UTC")!
        return (model, log)
    }

    func testSnapshotIsRedactedAndKeepsTheNewestTail() {
        let log = Log()
        log.log(.info, "QR", "scanned http://x/?ssid=CFMOTO-1&pwd=supersecret1")
        for i in 0 ..< 50 { log.log(.debug, "T", "line \(i)") }
        let full = SessionLogFiles.snapshot(log.lines(), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertFalse(full.contains("supersecret1"))
        XCTAssertTrue(full.contains("pwd=\(LogRedactor.mask)"))
        XCTAssertTrue(full.hasSuffix("D/T: line 49"))
        let lines = full.split(separator: "\n")
        XCTAssertEqual(lines.count, 51)
        let small = SessionLogFiles.snapshot(log.lines(), maxBytes: 200)
        XCTAssertLessThanOrEqual(small.utf8.count, 200)
        XCTAssertTrue(small.hasSuffix("D/T: line 49"))
        XCTAssertEqual(SessionLogFiles.tail("aaa\nbbb\nccc", maxBytes: 5), "ccc")
        XCTAssertEqual(SessionLogFiles.tail("short", maxBytes: 100), "short")
    }

    @MainActor
    func testTheSavedSessionIsConsumedAtLaunchAndSharedFirst() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (previous, oldLog) = makeModel(env)
        oldLog.log(.error, "LINK", "lost bike link (ride before the crash)")
        oldLog.log(.info, "QR", "http://x/?ssid=CFMOTO-1&pwd=supersecret1")
        previous.persistSession()
        let file = previous.sessionFiles.sessionURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "logs")

        // Next launch.
        let (model, log) = makeModel(env)
        model.hydrate()
        model.hydrate() // once per process
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) // consumed (no nesting)
        log.log(.info, "APP", "fresh launch")
        await LDTest.expect { model.entries.contains { $0.text.hasSuffix("fresh launch") } }
        let texts = model.entries.map(\.text)
        XCTAssertEqual(texts.first, SessionLogFiles.restoredBanner)
        XCTAssertTrue(texts.contains { $0.hasSuffix("lost bike link (ride before the crash)") })
        XCTAssertFalse(texts.joined().contains("supersecret1"))
        XCTAssertTrue(model.entries.prefix(3).allSatisfy { $0.id < 0 })
        XCTAssertEqual(Set(model.entries.map(\.id)).count, model.entries.count)

        let exported = try String(contentsOf: try model.exportLogs().url, encoding: .utf8)
        XCTAssertTrue(exported.hasPrefix(SessionLogFiles.restoredBanner + "\n"))
        XCTAssertTrue(exported.contains("lost bike link (ride before the crash)"))
        XCTAssertTrue(exported.contains("fresh launch"))
        let report = try String(contentsOf: try model.problemReport(problem: "dash went black", bikeModel: "800NK", bikeYear: "2024").url,
                                encoding: .utf8)
        XCTAssertTrue(report.contains(SessionLogFiles.restoredBanner))

        // Clear drops the restored part too.
        model.clear()
        await LDTest.expect { !model.entries.contains { $0.text == SessionLogFiles.restoredBanner } }
        XCTAssertFalse(try String(contentsOf: try model.exportLogs().url, encoding: .utf8).contains(SessionLogFiles.restoredBanner))
    }

    @MainActor
    func testACrashReportIsKeptUntilDismissedAndShared() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (model, _) = makeModel(env)
        model.hydrate()
        XCTAssertNil(model.crashReport)
        model.recordCrashReport("EXC_BAD_ACCESS (SIGSEGV)\nframe 0 OpenCfMoto 0x1234\n\nframe 1 libswiftCore")
        XCTAssertEqual(model.crashReport?.hasPrefix("EXC_BAD_ACCESS"), true)
        let exported = try String(contentsOf: try model.exportLogs().url, encoding: .utf8)
        XCTAssertTrue(exported.contains(SessionLogFiles.crashBanner + "\nEXC_BAD_ACCESS (SIGSEGV)\nframe 0 OpenCfMoto 0x1234\nframe 1 libswiftCore\n"
                                        + SessionLogFiles.crashEndBanner))

        // Still there at the next launch (Keep logs), until Dismiss.
        let (next, _) = makeModel(env)
        next.hydrate()
        XCTAssertNotNil(next.crashReport)
        next.dismissCrashReport()
        XCTAssertNil(next.crashReport)
        let (third, _) = makeModel(env)
        third.hydrate()
        XCTAssertNil(third.crashReport)
        model.recordCrashReport("   ")
        XCTAssertNotNil(model.crashReport) // blank reports are ignored
    }

    @MainActor
    func testAppModelSavesOnBackgroundAndWhileLinkedAndRestoresAtLaunch() async throws {
        let h = AppTestHarness()
        let files = h.model.logs.sessionFiles
        try? FileManager.default.removeItem(at: files.sessionURL)
        Log.i("TEST", "before going to the background")
        h.model.scenePhaseChanged(.background)
        let saved = try String(contentsOf: files.sessionURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("before going to the background"))

        // The next launch (same files) consumes it.
        h.model.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.sessionURL.path))
        XCTAssertEqual(h.model.logs.restoredSession?.contains("before going to the background"), true)

        // While a session runs, the log is saved periodically.
        let linked = AppTestHarness()
        linked.model.sessionLogInterval = 0.05
        linked.addBike()
        linked.model.start()
        let linkedFiles = linked.model.logs.sessionFiles
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkedFiles.sessionURL.path))
        linked.connection.connect()
        let written = await eventually { FileManager.default.fileExists(atPath: linkedFiles.sessionURL.path) }
        XCTAssertTrue(written)
        linked.connection.stop()
    }
}
