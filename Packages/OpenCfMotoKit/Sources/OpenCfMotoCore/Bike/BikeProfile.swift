// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) BikeProfile.kt
//
// A bike profile is the per-dashboard strategy selected from the bike's CLIENT_INFO (or early from
// the pairing QR): the `supportFunction` / `supportScreenTouch` we advertise, layout hints (panel
// size, default margins) and encoder defaults (docs/spec/control-plane.md §12).
// On iOS a profile is a value; the 8 Android profiles are the static members below.

import Foundation

/// One bike profile (Android `BikeProfile`), possibly wrapped with a learned panel size
/// (Android `LearnedGeometryProfile`).
public struct BikeProfile: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// A panel / canvas size in dash pixels.
    public struct PanelSize: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
        /// Android "wide" test used by the keep-landscape rule: `w >= h * 3 / 2` (integer math).
        public var isWide: Bool { width >= height * 3 / 2 }
        public var description: String { "\(width)x\(height)" }
    }

    /// Stable id (Android manual-override id where one exists).
    public let id: BikeProfileID
    /// Android profile name (log label), without the learned-geometry suffix.
    public let baseName: String
    /// QR `modelid` values that match this profile early (before CLIENT_INFO).
    public let qrModelIds: [String]
    /// Default for advertising `supportScreenTouch` in our CLIENT_INFO reply.
    public let supportsScreenTouch: Bool
    /// `supportFunction` advertised in our CLIENT_INFO reply (0 or 128).
    public let supportFunction: Int
    /// Android's (unused) sock-server-auth flag, kept for diagnostics.
    public let requiresSockServerAuth: Bool
    /// Whether this profile's reply builder appends `"supportScreenTouch":true` when touch is
    /// advertised (only the three CFDL26 profiles do; the others never send the key).
    public let appendsScreenTouchKey: Bool
    /// Typical / measured panel of the profile, nil = unknown.
    public let basePanelSize: PanelSize?
    /// Default insets until the rider customises them (800NK Advanced: top 22).
    public let defaultMargins: ScreenMargins
    /// Force H.264 Baseline @ 3.1 (every profile except Morini).
    public let forceBaseline: Bool
    /// Base bitrate in bit/s (before the quality multiplier).
    public let videoBitrate: Int
    /// Encoder frame rate.
    public let videoFrameRate: Int
    /// IDR interval in seconds.
    public let keyframeIntervalSeconds: Int
    /// Learned panel (REQ 16 raw size remembered per SSID) when this is a learned-geometry wrapper.
    public let measuredPanel: PanelSize?

    public init(id: BikeProfileID, baseName: String, qrModelIds: [String], supportsScreenTouch: Bool,
                supportFunction: Int, requiresSockServerAuth: Bool, appendsScreenTouchKey: Bool,
                basePanelSize: PanelSize?, defaultMargins: ScreenMargins = .zero, forceBaseline: Bool = true,
                videoBitrate: Int = 2_500_000, videoFrameRate: Int = 30, keyframeIntervalSeconds: Int = 1,
                measuredPanel: PanelSize? = nil) {
        self.id = id
        self.baseName = baseName
        self.qrModelIds = qrModelIds
        self.supportsScreenTouch = supportsScreenTouch
        self.supportFunction = supportFunction
        self.requiresSockServerAuth = requiresSockServerAuth
        self.appendsScreenTouchKey = appendsScreenTouchKey
        self.basePanelSize = basePanelSize
        self.defaultMargins = defaultMargins
        self.forceBaseline = forceBaseline
        self.videoBitrate = videoBitrate
        self.videoFrameRate = videoFrameRate
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        self.measuredPanel = measuredPanel
    }

    /// Log label; learned wrappers read `"<base> + measured WxH"`.
    public var name: String {
        guard let m = measuredPanel else { return baseName }
        return "\(baseName) + measured \(m.width)x\(m.height)"
    }

    /// Effective panel: the measured one for learned wrappers, else the profile's.
    public var panelSize: PanelSize? { measuredPanel ?? basePanelSize }

    /// True for a `LearnedGeometryProfile`-style wrapper.
    public var isLearnedGeometry: Bool { measuredPanel != nil }

    /// The same profile with a learned panel.
    public func withMeasuredPanel(_ panel: PanelSize?) -> BikeProfile {
        BikeProfile(id: id, baseName: baseName, qrModelIds: qrModelIds, supportsScreenTouch: supportsScreenTouch,
                    supportFunction: supportFunction, requiresSockServerAuth: requiresSockServerAuth,
                    appendsScreenTouchKey: appendsScreenTouchKey, basePanelSize: basePanelSize,
                    defaultMargins: defaultMargins, forceBaseline: forceBaseline, videoBitrate: videoBitrate,
                    videoFrameRate: videoFrameRate, keyframeIntervalSeconds: keyframeIntervalSeconds,
                    measuredPanel: panel)
    }

    /// The profile without any learned panel.
    public var base: BikeProfile { measuredPanel == nil ? self : withMeasuredPanel(nil) }

    /// Encoder defaults of this profile (before quality multiplier / power mode / adaptive policy).
    public var encoderDefaults: EncoderParameters {
        EncoderParameters(bitrate: videoBitrate, frameRate: videoFrameRate,
                          keyframeIntervalSeconds: Double(keyframeIntervalSeconds),
                          forceBaseline: forceBaseline, repeatLastFrameAfter: 0.9)
    }

    /// Early QR match (`modelId.trim()` in the profile's set).
    public func matchesModelId(_ modelId: String) -> Bool {
        qrModelIds.contains(modelId.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Capture rounding used for RLY 17: `(w & 0xFFF0, h & 0xFFF0)` — no profile overrides it.
    public func roundCaptureDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        (width & 0xFFF0, height & 0xFFF0)
    }

    /// Claim strength for a CLIENT_INFO (highest positive wins, 0 = no claim) — exact Android rules.
    public func score(_ info: BikeClientInfo) -> Int {
        BikeProfileScoring.score(id, info)
    }

    public var description: String { name }

    // ScreenMargins (contract) is not Hashable: hash the identity fields only (equal values share them).
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(measuredPanel)
    }

    // MARK: - The 8 Android profiles

    /// `LegacyCfdl16Profile` (675 SR-R, fallback).
    public static let legacy = BikeProfile(
        id: .legacy, baseName: "CFDL16 / legacy (BIKE A)", qrModelIds: ["37416"], supportsScreenTouch: false,
        supportFunction: 0, requiresSockServerAuth: false, appendsScreenTouchKey: false, basePanelSize: nil)

    /// `Nk800Profile` (US 800NK, CRCP / sdk 0.9.23.x, deliberately non-touch).
    public static let nk800 = BikeProfile(
        id: .nk800, baseName: "CFMoto 800NK (CRCP / sdk 0.9.23.x)", qrModelIds: ["66660703", "66660721", "66660732"],
        supportsScreenTouch: false, supportFunction: 128, requiresSockServerAuth: false, appendsScreenTouchKey: false,
        basePanelSize: nil)

    /// `Cfdl26PortraitProfile` (1000 MT-X; touch locked by default, handlebar-driven).
    public static let cfdl26Portrait = BikeProfile(
        id: .cfdl26Portrait, baseName: "CFDL26 / MotoPlay Portrait (1000 MT-X)", qrModelIds: ["37426"],
        supportsScreenTouch: false, supportFunction: 128, requiresSockServerAuth: true, appendsScreenTouchKey: true,
        basePanelSize: PanelSize(width: 800, height: 951))

    /// `Cfdl26NkTouchProfile` (800NK Advanced, near-square touch; 22 px top inset).
    public static let nkAdvanced = BikeProfile(
        id: .nkAdvanced, baseName: "CFDL26 / 800NK Advanced (touch, 720×712)", qrModelIds: ["37426"],
        supportsScreenTouch: true, supportFunction: 128, requiresSockServerAuth: true, appendsScreenTouchKey: true,
        basePanelSize: PanelSize(width: 720, height: 712), defaultMargins: ScreenMargins(top: 22))

    /// `Cfdl16MotoPlayLandscapeProfile` (modelId 66660742).
    public static let motoplayLandscape = BikeProfile(
        id: .motoplayLandscape, baseName: "CFDL16 / MotoPlay Landscape (modelId 66660742)", qrModelIds: ["66660742"],
        supportsScreenTouch: false, supportFunction: 128, requiresSockServerAuth: false, appendsScreenTouchKey: false,
        basePanelSize: PanelSize(width: 800, height: 400))

    /// `ClC450Profile` (CL-C450 near-square 544×512).
    public static let clc450 = BikeProfile(
        id: .clc450, baseName: "CL‑C450 (544×512)", qrModelIds: ["66660736", "CLC450"],
        supportsScreenTouch: false, supportFunction: 0, requiresSockServerAuth: false, appendsScreenTouchKey: false,
        basePanelSize: PanelSize(width: 544, height: 512))

    /// `MoriniMlSoftApProfile` (Morini SoftAP / Alltrhike; Ride MO encoder values: no forced
    /// Baseline, 2 Mbit/s, 10 fps, IDR every 2 s — EXPERIMENTAL on PXC).
    public static let morini = BikeProfile(
        id: .morini, baseName: "Morini SoftAP / Alltrhike (MLN)", qrModelIds: ["21333", "21322"],
        supportsScreenTouch: false, supportFunction: 128, requiresSockServerAuth: false, appendsScreenTouchKey: false,
        basePanelSize: PanelSize(width: 1024, height: 464), forceBaseline: false, videoBitrate: 2_000_000,
        videoFrameRate: 10, keyframeIntervalSeconds: 2)

    /// `Cfdl26LandscapeProfile` (800MT landscape touch).
    public static let cfdl26Landscape = BikeProfile(
        id: .cfdl26Landscape, baseName: "CFDL26 / MotoPlay Landscape (800MT)", qrModelIds: ["37426"],
        supportsScreenTouch: true, supportFunction: 128, requiresSockServerAuth: true, appendsScreenTouchKey: true,
        basePanelSize: PanelSize(width: 1280, height: 576))

    /// The profile for an id.
    public static func profile(_ id: BikeProfileID) -> BikeProfile {
        switch id {
        case .legacy: return legacy
        case .nk800: return nk800
        case .nkAdvanced: return nkAdvanced
        case .cfdl26Landscape: return cfdl26Landscape
        case .cfdl26Portrait: return cfdl26Portrait
        case .clc450: return clc450
        case .morini: return morini
        case .motoplayLandscape: return motoplayLandscape
        }
    }
}

/// The exact scoring rules of control-plane.md §12.4 (`BikeProfile.kt` `score()` functions).
/// `startsWith`/equality are case-sensitive unless marked; string ops use Java (UTF-16) semantics.
enum BikeProfileScoring {
    static func score(_ id: BikeProfileID, _ info: BikeClientInfo) -> Int {
        switch id {
        case .nk800: return nk800(info)
        case .nkAdvanced: return nkAdvanced(info)
        case .morini: return morini(info)
        case .motoplayLandscape: return motoplayLandscape(info)
        case .clc450: return clc450(info)
        case .cfdl26Landscape: return cfdl26Landscape(info)
        case .cfdl26Portrait: return cfdl26Portrait(info)
        case .legacy: return legacy(info)
        }
    }

    /// `BikeProfile.kt:420-426`
    static func legacy(_ i: BikeClientInfo) -> Int {
        var s = 1
        if i.optString("HUName").jStartsWith("CFDL16") { s += 4 }
        if i.optString("sdkVersion").jStartsWith("0.9.29") { s += 3 }
        if i.optString("channel").kotlinTrimmed == "37416" { s += 2 }
        return s
    }

    /// `BikeProfile.kt:479-489`
    static func nk800(_ i: BikeClientInfo) -> Int {
        let crcp = i.optString("HUID").jStartsWith("CRCP")
        let sdk0923 = i.optString("sdkVersion").jStartsWith("0.9.23")
        let linuxPkg = i.optString("package_name") == "linux_no_package"
        if !crcp, !(sdk0923 && linuxPkg) { return 0 }
        var s = 0
        if crcp { s += 4 }
        if sdk0923 { s += 3 }
        if linuxPkg { s += 2 }
        return s
    }

    /// `BikeProfile.kt:528-547`
    static func cfdl26Portrait(_ i: BikeClientInfo) -> Int {
        var s = 0
        if i.optString("HUID").jStartsWith("CARB", ignoreCase: true) { return 0 }
        let versionName = i.optString("version_name")
        let pkg = i.optString("package_name")
        let looks26 = looksCfmotoCfdl26(versionName: versionName, packageName: pkg)
        if versionName.jStartsWith("CFDL26") { s += 4 }
        let sdk = i.optString("sdkVersion")
        if looks26, !sdk.isEmpty, !sdk.jStartsWith("0.") { s += 2 }
        if i.optBoolean("enableSockServerAuth", false) { s += 2 }
        if pkg == "com.cfmoto.cfdashmotoplay" { s += 3 }
        if s > 0, i.optInt("supportFunction", 0) == 128 { s += 1 }
        return s
    }

    /// `BikeProfile.kt:602-619`
    static func nkAdvanced(_ i: BikeClientInfo) -> Int {
        var s = 0
        if i.optString("version_name").jStartsWith("CFDL26") { s += 4 }
        if i.optString("package_name") == "com.cfmoto.easyconnect" { s += 3 }
        if i.optBoolean("enableSockServerAuth", false) { s += 2 }
        let sdk = i.optString("sdkVersion")
        if !sdk.isEmpty, !sdk.jStartsWith("0.") { s += 2 }
        if s > 0, i.optInt("supportFunction", 0) == 128 { s += 1 }
        if i.optString("HUID").jStartsWith("6KWV") { s += 4 }
        if i.optBoolean("supportLandscapeAdaptive", false) { s -= 4 }
        if i.optBoolean("supportMirrorOverlayTouch", false) { s += 1 }
        if i.optBoolean("supportScreenTouch", false) { s += 1 }
        return s
    }

    /// `BikeProfile.kt:642-649`
    static func motoplayLandscape(_ i: BikeClientInfo) -> Int {
        var s = 0
        if i.optString("channel") == "66660742" { s += 10 }
        if i.optString("sdkVersion").jStartsWith("0.9") { s += 2 }
        if i.optBoolean("supportLandscapeAdaptive", false) { s += 1 }
        if !i.optBoolean("supportScreenTouch", false) { s += 1 }
        return s
    }

    /// `BikeProfile.kt:671-677`
    static func clc450(_ i: BikeClientInfo) -> Int {
        var s = 0
        if i.optString("channel") == "66660736" { s += 8 }
        if i.optString("HUName").jContains("48FB4C", ignoreCase: true) { s += 4 }
        if i.optString("sdkVersion").jStartsWith("0.9.23") { s += 1 }
        return s
    }

    /// `BikeProfile.kt:728-741`
    static func morini(_ i: BikeClientInfo) -> Int {
        var s = 0
        let channel = i.optString("channel")
        if channel == "21333" || channel == "21322" { s += 12 }
        if i.optString("HUID").jStartsWith("CARB", ignoreCase: true) { s += 8 }
        if i.optInt("flavor", 0) == 51 { s += 6 }
        if i.optString("package_name").isEmpty, s > 0 { s += 1 }
        if i.optString("sdkVersion").jStartsWith("1.0.13") { s += 2 }
        if !i.optBoolean("supportScreenTouch", false) { s += 1 }
        return s
    }

    /// `BikeProfile.kt:767-790`
    static func cfdl26Landscape(_ i: BikeClientInfo) -> Int {
        var s = 0
        let versionName = i.optString("version_name")
        let pkg = i.optString("package_name")
        let looks26 = looksCfmotoCfdl26(versionName: versionName, packageName: pkg)
        if versionName.jStartsWith("CFDL26") { s += 4 }
        let sdk = i.optString("sdkVersion")
        if looks26, !sdk.isEmpty, !sdk.jStartsWith("0.") { s += 2 }
        if i.optBoolean("enableSockServerAuth", false) { s += 2 }
        if pkg == "com.cfmoto.easyconnect" { s += 3 }
        if s > 0, i.optInt("supportFunction", 0) == 128 { s += 1 }
        if looks26, i.optBoolean("supportLandscapeAdaptive", false) { s += 4 }
        if i.optString("HUID").jStartsWith("6WWV") { s += 3 }
        if !i.optBoolean("supportScreenTouch", false) { s -= 1 }
        if i.optString("HUID").jStartsWith("CARB", ignoreCase: true) { s = 0 }
        return s
    }

    static func looksCfmotoCfdl26(versionName: String, packageName: String) -> Bool {
        versionName.jStartsWith("CFDL26") || packageName.jContains("cfmoto", ignoreCase: true) ||
            packageName.jContains("cfdash", ignoreCase: true)
    }
}

// MARK: - Java/Kotlin string semantics (UTF-16 based)

fileprivate extension String {
    /// Kotlin `startsWith(prefix, ignoreCase)` over UTF-16 code units.
    func jStartsWith(_ prefix: String, ignoreCase: Bool = false) -> Bool {
        let a = Array(utf16), p = Array(prefix.utf16)
        guard p.count <= a.count else { return false }
        for k in 0 ..< p.count where !BikeProfileScoringChar.equal(a[k], p[k], ignoreCase: ignoreCase) { return false }
        return true
    }

    /// Kotlin `contains(other, ignoreCase)` over UTF-16 code units.
    func jContains(_ needle: String, ignoreCase: Bool = false) -> Bool {
        let a = Array(utf16), p = Array(needle.utf16)
        if p.isEmpty { return true }
        guard p.count <= a.count else { return false }
        outer: for start in 0 ... (a.count - p.count) {
            for k in 0 ..< p.count where !BikeProfileScoringChar.equal(a[start + k], p[k], ignoreCase: ignoreCase) {
                continue outer
            }
            return true
        }
        return false
    }

    /// Kotlin `trim()` (Unicode whitespace at both ends).
    var kotlinTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

fileprivate enum BikeProfileScoringChar {
    /// Kotlin `Char.equals(other, ignoreCase)`: ASCII letters fold; other units compare exactly.
    static func equal(_ a: UInt16, _ b: UInt16, ignoreCase: Bool) -> Bool {
        if a == b { return true }
        guard ignoreCase else { return false }
        return fold(a) == fold(b)
    }

    static func fold(_ c: UInt16) -> UInt16 {
        (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c
    }
}
