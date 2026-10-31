// SPDX-License-Identifier: AGPL-3.0-or-later
// ProblemReport.kt template (app-features.md §6.5 worked example).

import XCTest
@testable import OpenCfMotoCore

final class ProblemReportTests: XCTestCase {

    static let diagnostics = ProblemReport.Diagnostics(
        appVersion: "2.0.18", buildNumber: "77", gitHash: "0abbe2a",
        profileName: SettingsBackup.androidProfileName(.nkAdvanced), profileOverride: nil, wifiTransport: .auto,
        marginsSummary: CanvasFit.marginsSummary(ScreenMargins(), profileDefault: CanvasFit.profileDefaultMargins(.nkAdvanced)),
        forceNonTouch: false, forceTouch: false, ssid: "CFMOTO-805120", phase: "ERROR",
        phaseDetail: "Bike Wi\u{2011}Fi is up but EasyConn is offline \u{2014} keep the pairing QR open on the dash")

    static let diagnosticsText = """
    app=2.0.18 (77) git=0abbe2a
    profile=CFDL26 / 800NK Advanced (touch, 720\u{00D7}712)
    override=AUTO
    transport=Auto (from QR)
    margins=Top 22 \u{00B7} bottom 0 \u{00B7} left 0 \u{00B7} right 0 px (profile default)
    forceNonTouch=false
    forceTouch=false
    ssid=CFMOTO-805120
    phase=ERROR Bike Wi\u{2011}Fi is up but EasyConn is offline \u{2014} keep the pairing QR open on the dash

    """

    func testDiagnosticsBlock() {
        XCTAssertEqual(Self.diagnostics.text, Self.diagnosticsText)
        var d = Self.diagnostics
        d.ssid = nil
        d.profileOverride = .cfdl26Portrait
        d.wifiTransport = .ap
        XCTAssertTrue(d.text.contains("ssid=\u{2014}\n"))
        XCTAssertTrue(d.text.contains("override=CFDL26_PORT\n"))
        XCTAssertTrue(d.text.contains("transport=Force Wi\u{2011}Fi AP\n"))
        XCTAssertEqual(ProblemReport.overrideEnumName(.nkAdvanced), "NK_ADV")
        XCTAssertEqual(ProblemReport.transportLabel(.p2p), "Force Wi\u{2011}Fi Direct")
    }

    func testWorkedExampleFile() {
        let rule = String(repeating: "\u{2550}", count: 56)
        let log = "19:02:11.402  [BUILD] versionName=2.0.18 \u{2026}"
        let expected = rule + "\nOpenCfMoto problem report\n" + rule + "\n\nWHAT WENT WRONG\nDash stays black after Connect\n\nBIKE\nCFMOTO 800NK Advanced, 2025\n\nSETUP\n"
            + Self.diagnosticsText.trimmingCharacters(in: .newlines)
            + "\n\n" + rule + "\nLOG \u{2014} passwords and serials removed unless \"include secrets\" is on\n" + rule + "\n" + log
        let file = ProblemReport.file(problem: "  Dash stays black after Connect\n", model: "800NK Advanced", year: " 2025 ",
                                      diagnostics: Self.diagnostics.text, log: log)
        XCTAssertEqual(file, expected)
        XCTAssertEqual(ProblemReport.rule, rule)
    }

    func testBodyAndSubject() {
        let body = ProblemReport.body(problem: "Dash stays black", model: "800NK Advanced", year: "2025", diagnostics: Self.diagnostics.text)
        XCTAssertEqual(body, "### What went wrong\nDash stays black\n\n### Bike\nCFMOTO 800NK Advanced, 2025\n\n### Setup\n```\n"
                       + Self.diagnosticsText.trimmingCharacters(in: .newlines)
                       + "\n```\n\nFull log attached. Secrets redacted unless enabled in Setup.")
        XCTAssertEqual(ProblemReport.subject(model: "800NK Advanced", version: "2.0.18"), "OpenCfMoto CFMOTO 800NK Advanced report \u{2014} 2.0.18")
        XCTAssertEqual(ProblemReport.subject(model: "  ", version: "0.1.0"), "OpenCfMoto CFMOTO unknown model report \u{2014} 0.1.0")
    }

    func testBikeLine() {
        XCTAssertEqual(ProblemReport.bikeLine(model: "", year: ""), "CFMOTO unknown model")
        XCTAssertEqual(ProblemReport.bikeLine(model: "Voge DS900X", year: ""), "CFMOTO Voge DS900X")
        XCTAssertEqual(ProblemReport.bikeLine(model: " 450NK ", year: "2024"), "CFMOTO 450NK, 2024")
    }

    func testBuildAppliesCallerSemantics() {
        let r = ProblemReport.build(problem: "   ", model: "X", year: "", diagnostics: "a=1\n", log: "L", appVersion: "0.1.0")
        XCTAssertTrue(r.fileText.contains("WHAT WENT WRONG\n(not specified)\n"))
        XCTAssertTrue(r.bodyText.hasPrefix("### What went wrong\n\n"))        // body uses the raw (blank) text
        XCTAssertTrue(r.fileText.hasSuffix("\nL"))
        XCTAssertEqual(r.subject, "OpenCfMoto CFMOTO X report \u{2014} 0.1.0")
        XCTAssertEqual(ProblemReport.fileName, "opencfmoto-report.txt")
    }
}
