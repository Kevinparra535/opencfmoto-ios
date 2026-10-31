// SPDX-License-Identifier: AGPL-3.0-or-later
// Golden output of the UPSTREAM Kotlin ProblemReport.kt on a JVM.

import XCTest
@testable import OpenCfMotoCore

final class ProblemReportGoldenTests: XCTestCase {
    func testMatchesKotlin() {
        XCTAssertEqual(ProblemReport.file(problem: "  It broke\n", model: " 450SR ", year: "2024 ", diagnostics: "app=1\nx=2\n",
                                          log: "LOG LINE 1\nLOG LINE 2"), Self.reportFile)
        XCTAssertEqual(ProblemReport.body(problem: "", model: "", year: "", diagnostics: "a=b"), Self.reportBody)
        XCTAssertEqual(ProblemReport.subject(model: " Voge ", version: "2.0.18"), Self.reportSubject)
    }
}

extension ProblemReportGoldenTests {
    static let reportFile = "\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{a}OpenCfMoto problem report\u{a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{a}\u{a}WHAT WENT WRONG\u{a}It broke\u{a}\u{a}BIKE\u{a}CFMOTO 450SR, 2024\u{a}\u{a}SETUP\u{a}app=1\u{a}x=2\u{a}\u{a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{a}LOG \u{2014} passwords and serials removed unless \"include secrets\" is on\u{a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{a}LOG LINE 1\u{a}LOG LINE 2"
    static let reportBody = "### What went wrong\u{a}\u{a}\u{a}### Bike\u{a}CFMOTO unknown model\u{a}\u{a}### Setup\u{a}```\u{a}a=b\u{a}```\u{a}\u{a}Full log attached. Secrets redacted unless enabled in Setup."
    static let reportSubject = "OpenCfMoto CFMOTO Voge report \u{2014} 2.0.18"
}
