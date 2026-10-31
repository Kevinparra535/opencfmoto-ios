// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) ProblemReport.kt, MainActivity.kt (shareProblemReport diagnostics)
//
// "Report a problem" text (app-features.md §6.5): the shared file, the message body, the subject and
// the diagnostics block, with Android's exact template. The log passed in must already be redacted
// (unless the rider enabled "include secrets").

import Foundation

public enum ProblemReport {
    /// 56 × `═` (U+2550).
    public static let rule = String(repeating: "\u{2550}", count: 56)
    /// File text used when the rider leaves "What went wrong?" blank.
    public static let notSpecified = "(not specified)"
    /// Shared file name (`cacheDir/logs/opencfmoto-report.txt` on Android).
    public static let fileName = "opencfmoto-report.txt"

    /// `"CFMOTO " + (model.trim() or "unknown model") + (", " + year.trim() if not empty)` — always
    /// prefixed `CFMOTO`, like Android.
    public static func bikeLine(model: String, year: String) -> String {
        let trimmed = AppJvmText.trim(model)
        let m = trimmed.isEmpty ? "unknown model" : trimmed
        let y = AppJvmText.trim(year)
        return y.isEmpty ? "CFMOTO \(m)" : "CFMOTO \(m), \(y)"
    }

    /// The report file (`ProblemReport.file`). `log` is appended verbatim (no trailing newline added).
    public static func file(problem: String, model: String, year: String, diagnostics: String, log: String) -> String {
        var s = ""
        func line(_ t: String = "") { s += t + "\n" }
        line(rule)
        line("OpenCfMoto problem report")
        line(rule)
        line()
        line("WHAT WENT WRONG")
        line(AppJvmText.trim(problem))
        line()
        line("BIKE")
        line(bikeLine(model: model, year: year))
        line()
        line("SETUP")
        line(AppJvmText.trim(diagnostics))
        line()
        line(rule)
        line("LOG \u{2014} passwords and serials removed unless \"include secrets\" is on")
        line(rule)
        s += log
        return s
    }

    /// The share-sheet message body (`ProblemReport.body`) — uses the raw problem text.
    public static func body(problem: String, model: String, year: String, diagnostics: String) -> String {
        var s = ""
        func line(_ t: String = "") { s += t + "\n" }
        line("### What went wrong")
        line(AppJvmText.trim(problem))
        line()
        line("### Bike")
        line(bikeLine(model: model, year: year))
        line()
        line("### Setup")
        line("```")
        line(AppJvmText.trim(diagnostics))
        line("```")
        line()
        s += "Full log attached. Secrets redacted unless enabled in Setup."
        return s
    }

    /// `OpenCfMoto <bikeLine(model, "")> report — <version>`.
    public static func subject(model: String, version: String) -> String {
        "OpenCfMoto \(bikeLine(model: model, year: "")) report \u{2014} \(version)"
    }

    /// Everything Android shares, with its caller semantics (blank problem → `(not specified)` in
    /// the file only).
    public struct Report: Sendable, Equatable {
        public var fileText: String
        public var bodyText: String
        public var subject: String
    }

    public static func build(problem: String, model: String, year: String, diagnostics: String, log: String,
                             appVersion: String) -> Report {
        let fileProblem = AppJvmText.isBlank(problem) ? notSpecified : problem
        return Report(fileText: file(problem: fileProblem, model: model, year: year, diagnostics: diagnostics, log: log),
                      bodyText: body(problem: problem, model: model, year: year, diagnostics: diagnostics),
                      subject: subject(model: model, version: appVersion))
    }

    // MARK: - Diagnostics block

    /// The `SETUP` lines (MainActivity.kt:1653-1666).
    public struct Diagnostics: Sendable, Equatable {
        public var appVersion: String
        public var buildNumber: String
        public var gitHash: String
        /// Android display name of the active profile (`SettingsBackup.androidProfileName`).
        public var profileName: String
        public var profileOverride: BikeProfileID?
        public var wifiTransport: WifiTransport
        /// `CanvasFit.marginsSummary(…)`.
        public var marginsSummary: String
        public var forceNonTouch: Bool
        public var forceTouch: Bool
        /// Selected bike SSID (nil → `—`).
        public var ssid: String?
        /// Connection phase NAME (e.g. `STREAMING`, `ERROR`).
        public var phase: String
        public var phaseDetail: String

        public init(appVersion: String, buildNumber: String, gitHash: String, profileName: String,
                    profileOverride: BikeProfileID?, wifiTransport: WifiTransport, marginsSummary: String,
                    forceNonTouch: Bool, forceTouch: Bool, ssid: String?, phase: String, phaseDetail: String) {
            self.appVersion = appVersion
            self.buildNumber = buildNumber
            self.gitHash = gitHash
            self.profileName = profileName
            self.profileOverride = profileOverride
            self.wifiTransport = wifiTransport
            self.marginsSummary = marginsSummary
            self.forceNonTouch = forceNonTouch
            self.forceTouch = forceTouch
            self.ssid = ssid
            self.phase = phase
            self.phaseDetail = phaseDetail
        }

        /// One `key=value` per line, each ending with `\n` (Kotlin `appendLine`).
        public var text: String {
            var s = ""
            s += "app=\(appVersion) (\(buildNumber)) git=\(gitHash)\n"
            s += "profile=\(profileName)\n"
            s += "override=\(ProblemReport.overrideEnumName(profileOverride))\n"
            s += "transport=\(ProblemReport.transportLabel(wifiTransport))\n"
            s += "margins=\(marginsSummary)\n"
            s += "forceNonTouch=\(forceNonTouch)\n"
            s += "forceTouch=\(forceTouch)\n"
            s += "ssid=\(ssid ?? "\u{2014}")\n"
            s += "phase=\(phase) \(phaseDetail)\n"
            return s
        }
    }

    /// Android `ProfileOverride` enum NAME (`AUTO`, `LEGACY`, `NK800`, `NK_ADV`, `CFDL26_LAND`,
    /// `CFDL26_PORT`, `CLC450`; iOS-only: `MORINI`, `MOTOPLAY_LAND`).
    public static func overrideEnumName(_ p: BikeProfileID?) -> String {
        switch p {
        case nil: return "AUTO"
        case .legacy?: return "LEGACY"
        case .nk800?: return "NK800"
        case .nkAdvanced?: return "NK_ADV"
        case .cfdl26Landscape?: return "CFDL26_LAND"
        case .cfdl26Portrait?: return "CFDL26_PORT"
        case .clc450?: return "CLC450"
        case .morini?: return "MORINI"
        case .motoplayLandscape?: return "MOTOPLAY_LAND"
        }
    }

    /// Android `WifiTransport.label` (U+2011 in "Wi‑Fi").
    public static func transportLabel(_ t: WifiTransport) -> String {
        switch t {
        case .auto: return "Auto (from QR)"
        case .ap: return "Force Wi\u{2011}Fi AP"
        case .p2p: return "Force Wi\u{2011}Fi Direct"
        }
    }
}
