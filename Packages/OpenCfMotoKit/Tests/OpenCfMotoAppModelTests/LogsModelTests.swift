// SPDX-License-Identifier: AGPL-3.0-or-later
// LogsModel: log-bus subscription (throttled, newest 1000, level filter), on-screen + export
// redaction (retroactive "include secrets"), clear + banner, problem report
// (docs/spec/app-features.md §6). Uses a private `Log` bus so other tests cannot interfere.

import Foundation
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoAppModel

final class LogsModelTests: XCTestCase {

    override func tearDown() {
        LogRedactor.install(on: .shared, includeSecrets: false)
        super.tearDown()
    }

    @MainActor
    private func makeModel(_ env: LDTestEnv, throttle: TimeInterval = 0.02) -> (LogsModel, Log) {
        let log = Log()
        let model = LogsModel(core: env.core, log: log)
        model.throttleInterval = throttle
        return (model, log)
    }

    // MARK: Entries

    @MainActor
    func testEntriesMirrorTheBusWithLevelsAndFilter() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (model, log) = makeModel(env)
        XCTAssertTrue(model.entries.isEmpty)

        log.log(.debug, "PXC", "probe sent")
        log.log(.info, "NAV", "route ready")
        log.log(.warn, "WIFI", "join slow")
        log.log(.error, "LINK", "lost bike link")
        await LDTest.expect { model.entries.count == 4 }
        XCTAssertEqual(model.entries.map(\.level), [.debug, .info, .warning, .error])
        // Same text as the bus formats it (`HH:mm:ss.SSS L/TAG: msg`), oldest first.
        XCTAssertEqual(model.entries.map(\.text), log.lines().map { $0.formatted(redactor: log.redactor) })
        XCTAssertEqual(model.entries.map(\.id), log.lines().map { Int($0.id) })
        XCTAssertEqual(model.entries.map { LogsModel.levelTag(ofLine: $0.text) }, [.debug, .info, .warning, .error])

        model.minimumLevel = .warning
        XCTAssertEqual(model.entries.map(\.level), [.warning, .error])
        model.minimumLevel = .error
        XCTAssertEqual(model.entries.count, 1)
        model.minimumLevel = nil
        XCTAssertEqual(model.entries.count, 4)
    }

    @MainActor
    func testKeepsTheNewest1000AndThrottlesUpdates() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (model, log) = makeModel(env, throttle: 1.0)
        for i in 0 ..< 1200 { log.log(.info, "T", "line \(i)") }
        await LDTest.expect { model.entries.count == 1000 }
        XCTAssertTrue(model.entries.first!.text.hasSuffix("I/T: line 200"), model.entries.first!.text)
        XCTAssertTrue(model.entries.last!.text.hasSuffix("I/T: line 1199"), model.entries.last!.text)

        // ≤ 4 Hz: a line logged right after a refresh waits for the throttle interval.
        log.log(.info, "T", "late line")
        await LDTest.settle(0.1)
        XCTAssertFalse(model.entries.last!.text.hasSuffix("late line"))
        await LDTest.expect(timeout: 5) { model.entries.last!.text.hasSuffix("late line") }
        XCTAssertEqual(model.entries.count, 1000)

        // The level filter applies before the 1000 cap.
        log.log(.error, "T", "only error")
        model.minimumLevel = .error
        XCTAssertEqual(model.entries.count, 1)
    }

    func testLevelParsingAndPhaseNames() async {
        await MainActor.run {
            XCTAssertEqual(LogsModel.levelTag(ofLine: "12:00:00.000 D/PXC: x"), .debug)
            XCTAssertEqual(LogsModel.levelTag(ofLine: "12:00:00.000 I/NAV: x"), .info)
            XCTAssertEqual(LogsModel.levelTag(ofLine: "12:00:00.000 W/NAV: x"), .warning)
            XCTAssertEqual(LogsModel.levelTag(ofLine: "12:00:00.000 E/LINK: x"), .error)
            XCTAssertNil(LogsModel.levelTag(ofLine: "garbage"))
            XCTAssertNil(LogsModel.levelTag(ofLine: "12:00:00.000 X/T: x"))
            XCTAssertEqual(LogsModel.levelTag(letter: LogLevel.warn.letter), .warning)

            XCTAssertEqual(LogsModel.androidPhaseName("idle"), "IDLE")
            XCTAssertEqual(LogsModel.androidPhaseName("joiningWifi"), "JOINING_WIFI")
            XCTAssertEqual(LogsModel.androidPhaseName("linking"), "PXC_CONNECTING")
            XCTAssertEqual(LogsModel.androidPhaseName("streaming"), "STREAMING")
            XCTAssertEqual(LogsModel.androidPhaseName("mirroring"), "MIRRORING")
            XCTAssertEqual(LogsModel.androidPhaseName("reconnecting"), "RECONNECTING")
            XCTAssertEqual(LogsModel.androidPhaseName("waitingForBike"), "WAITING_FOR_BIKE")
            XCTAssertEqual(LogsModel.androidPhaseName("stopped"), "STOPPED")
            XCTAssertEqual(LogsModel.androidPhaseName("error"), "ERROR")
            XCTAssertEqual(LogsModel.androidPhaseName("STREAMING"), "STREAMING")
        }
    }

    // MARK: Redaction / export

    @MainActor
    func testRedactionOnScreenAndInExportsIsRetroactive() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (model, log) = makeModel(env)
        model.timeZone = TimeZone(identifier: "UTC")!
        log.log(.info, "QR", "QR raw: \(LDTest.docQR)")
        log.log(.info, "PXC", #"CLIENT_INFO {"HUID":"6GUVA2C00100055","HUName":"CFMOTO-805120","btPin":"1234"}"#)
        await LDTest.expect { model.entries.count == 2 }
        XCTAssertFalse(model.entries.contains { $0.text.contains(LDTest.docPassword) })
        XCTAssertTrue(model.entries[0].text.contains("pwd=\u{00AB}redacted\u{00BB}"), model.entries[0].text)
        XCTAssertTrue(model.entries[1].text.contains(#""HUID":"6GUV…********""#), model.entries[1].text)

        let file = try model.exportLogs()
        XCTAssertEqual(file.fileName, "opencfmoto-log-20261031-154207.txt")
        XCTAssertEqual(file.typeIdentifier, "public.plain-text")
        XCTAssertEqual(file.url.deletingLastPathComponent().standardizedFileURL.path,
                       env.services.files.exportsDirectory.standardizedFileURL.path)
        let text = LDTest.read(file)
        XCTAssertFalse(text.contains(LDTest.docPassword))
        XCTAssertFalse(text.contains("6GUVA2C00100055"))
        XCTAssertFalse(text.contains(#""btPin":"1234""#))
        XCTAssertTrue(text.contains("ssid=CFMOTO-f46457"))   // SSIDs are kept on purpose
        XCTAssertTrue(text.hasSuffix("\n"))

        // "Include secrets in shared logs" on: the screen and the export show the raw lines.
        env.core.settings.update(forBike: nil) { $0.includeSecretsInLogs = true }
        await LDTest.expect { model.entries.contains { $0.text.contains(LDTest.docPassword) } }
        XCTAssertNil(log.redactor)
        XCTAssertTrue(LDTest.read(try model.exportLogs()).contains(LDTest.docPassword))

        env.core.settings.update(forBike: nil) { $0.includeSecretsInLogs = false }
        await LDTest.expect { !model.entries.contains { $0.text.contains(LDTest.docPassword) } }
        XCTAssertNotNil(log.redactor)
        XCTAssertFalse(LDTest.read(try model.exportLogs()).contains(LDTest.docPassword))
    }

    @MainActor
    func testSharedBusGetsTheRedactorAtInit() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        Log.shared.redactor = nil
        _ = LogsModel(core: env.core)
        XCTAssertNotNil(Log.shared.redactor, "redaction is on by default")
        env.core.settings.update(forBike: nil) { $0.includeSecretsInLogs = true }
        _ = LogsModel(core: env.core)
        XCTAssertNil(Log.shared.redactor)
    }

    // MARK: Clear

    @MainActor
    func testClearEmptiesAndRelogsTheBanner() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (model, log) = makeModel(env)
        log.log(.info, "X", "hello")
        await LDTest.expect { model.entries.count == 1 }
        model.clear()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(log.lines().map(\.tag), ["BUILD", "BUILD"])
        XCTAssertEqual(log.lines().first?.message, "versionName=0.1.0 versionCode=1 device=iPhone-Preview os=iOS 18.0 flavor=full")
        XCTAssertEqual(log.lines().last?.message, "--- session start ---")
        await LDTest.expect { model.entries.count == 2 }
        XCTAssertFalse(model.entries.contains { $0.text.contains("hello") })
    }

    // MARK: Problem report

    @MainActor
    func testProblemReport() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (model, log) = makeModel(env)
        let garage = GarageModel(core: env.core)
        guard case let .paired(bike) = garage.pair(rawQR: LDTest.docQR) else { return XCTFail("pairing failed") }
        env.core.garage.setProfileHint(bike.id, .nkAdvanced)
        log.log(.info, "QR", "QR raw: \(LDTest.docQR)")
        model.diagnostics = { ["phase": "error", "detail": "lost bike link", "canvas": "720x704", "stats": "fps=24"] }

        let file = try model.problemReport(problem: "  Dash stays black after Connect ", bikeModel: "800NK Advanced",
                                           bikeYear: "2025")
        XCTAssertEqual(file.fileName, "opencfmoto-report.txt")
        XCTAssertEqual(file.typeIdentifier, "public.plain-text")
        let text = LDTest.read(file)
        let rule = String(repeating: "\u{2550}", count: 56)
        let expectedHead = """
        \(rule)
        OpenCfMoto problem report
        \(rule)

        WHAT WENT WRONG
        Dash stays black after Connect

        BIKE
        CFMOTO 800NK Advanced, 2025

        SETUP
        app=0.1.0 (1) git=n/a
        profile=CFDL26 / 800NK Advanced (touch, 720\u{00D7}712)
        override=AUTO
        transport=Auto (from QR)
        margins=Top 22 \u{00B7} bottom 0 \u{00B7} left 0 \u{00B7} right 0 px (profile default)
        forceNonTouch=false
        forceTouch=false
        ssid=CFMOTO-f46457
        phase=ERROR lost bike link
        device=iPhone-Preview iOS 18.0 flavor=full
        canvas=720x704
        stats=fps=24

        \(rule)
        LOG \u{2014} passwords and serials removed unless "include secrets" is on
        \(rule)

        """
        XCTAssertTrue(text.hasPrefix(expectedHead), text)
        XCTAssertTrue(text.contains("QR raw: http://www.carbit.com.cn/"))
        XCTAssertFalse(text.contains(LDTest.docPassword), "the report log must be redacted")

        // Explicit diagnostics win; a blank problem reads "(not specified)".
        model.diagnostics = { ["profile": "Custom profile", "ssid": "DASH-1", "git": "abc1234", "phase": "STREAMING"] }
        let second = LDTest.read(try model.problemReport(problem: "   ", bikeModel: "", bikeYear: ""))
        XCTAssertTrue(second.contains("WHAT WENT WRONG\n(not specified)\n"), second)
        XCTAssertTrue(second.contains("BIKE\nCFMOTO unknown model\n"), second)
        XCTAssertTrue(second.contains("app=0.1.0 (1) git=abc1234\nprofile=Custom profile\n"), second)
        XCTAssertTrue(second.contains("ssid=DASH-1\nphase=STREAMING \n"), second)
    }
}
