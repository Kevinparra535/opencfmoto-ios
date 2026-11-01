// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) SettingsBackup.kt
//
// The portable bike-tuning pack `{"format":"opencfmoto.settings","version":1,…}` (app-features.md §3):
// export byte-identical to Android (`JSONObject.toString(2)`, key order, `exportedAt` pattern) and
// import with Android's validation, apply order, leniency and verbatim messages. iOS-only keys live
// inside `settings` with an `ios` prefix (Android ignores unknown keys); `version` is never bumped.
// Never exported: QR passwords, SSIDs, serials, bike names, photos, ORS key, personal prefs.

import Foundation

public enum SettingsBackup {
    public static let format = "opencfmoto.settings"
    public static let version = 1

    /// iOS-only keys written inside `settings` (Android ignores them).
    public enum IOSKey {
        /// Keep the iPhone screen awake while projecting (`BikeSettings.keepScreenOn`).
        public static let keepScreenOn = "iosKeepScreenOn"
    }

    // MARK: - Profile names (`bikeHint.profile`)

    /// Android display name of a profile (`BikeProfile.name`), optionally wrapped by the learned
    /// geometry (`"<base> + measured <w>x<h>"`). nil → the legacy profile (Android's holder default).
    public static func androidProfileName(_ profile: BikeProfileID?, learned: LearnedDashSize? = nil) -> String {
        let base: String
        switch profile ?? .legacy {
        case .legacy: base = "CFDL16 / legacy (BIKE A)"
        case .nk800: base = "CFMoto 800NK (CRCP / sdk 0.9.23.x)"
        case .nkAdvanced: base = "CFDL26 / 800NK Advanced (touch, 720\u{00D7}712)"
        case .cfdl26Landscape: base = "CFDL26 / MotoPlay Landscape (800MT)"
        case .cfdl26Portrait: base = "CFDL26 / MotoPlay Portrait (1000 MT-X)"
        case .clc450: base = "CL\u{2011}C450 (544\u{00D7}512)"
        case .morini: base = "Morini SoftAP / Alltrhike (MLN)"
        case .motoplayLandscape: base = "CFDL16 / MotoPlay Landscape (modelId 66660742)"
        }
        guard let learned else { return base }
        return "\(base) + measured \(learned.width)x\(learned.height)"
    }

    /// Android short label of a profile override (`ProfileOverride.shortLabel`); nil → `Auto`.
    public static func overrideShortLabel(_ profile: BikeProfileID?) -> String {
        switch profile {
        case nil: return "Auto"
        case .legacy?: return "Legacy"
        case .nk800?: return "800NK"
        case .nkAdvanced?: return "800NK Adv"
        case .cfdl26Landscape?: return "800MT"
        case .cfdl26Portrait?: return "1000 MT-X"
        case .clc450?: return "CL\u{2011}C450"
        case .morini?: return "Morini"
        case .motoplayLandscape?: return "MotoPlay Landscape"
        }
    }

    /// `OpenCfMoto-<slug>-settings.json` (slug = override id, `auto` when automatic).
    public static func suggestedFileName(profileOverride: BikeProfileID?) -> String {
        "OpenCfMoto-\(profileOverride?.rawValue ?? "auto")-settings.json"
    }

    /// Share-sheet subject: `OpenCfMoto bike tuning — <shortLabel>`.
    public static func shareSubject(profileOverride: BikeProfileID?) -> String {
        "OpenCfMoto bike tuning \u{2014} \(overrideShortLabel(profileOverride))"
    }

    // MARK: - Export

    /// `exportedAt`: `yyyy-MM-dd'T'HH:mm:ssXXX` (`Z` for UTC, else `+01:00`), en_US_POSIX.
    public static func exportedAtString(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return f.string(from: date)
    }

    /// The pack as an ordered JSON object (exact Android key order).
    public static func exportObject(settings s: BikeSettings, androidOnly a: AndroidOnlySettings,
                                    profileName: String, appVersion: String,
                                    date: Date = Date(), timeZone: TimeZone = .current) -> OrderedJSONObject {
        var root = OrderedJSONObject()
        root.put("format", format)
        root.put("version", version)
        root.put("exportedAt", exportedAtString(date, timeZone: timeZone))
        root.put("appVersion", appVersion)
        var hint = OrderedJSONObject()
        hint.put("profile", profileName)
        hint.put("profileOverride", s.profileOverride?.rawValue ?? "auto")
        root.put("bikeHint", hint)

        var o = OrderedJSONObject()
        o.put("videoQuality", s.videoQuality.rawValue)
        o.put("screenFit", s.screenFit.rawValue)
        o.put("mirrorOrientation", s.mirrorOrientation.rawValue)
        o.put("powerMode", s.powerMode.rawValue)
        o.put("resolutionMode", a.resolutionMode.rawValue)
        o.put("aaDpiOverride", a.aaDpiOverride > 0 ? a.aaDpiOverride : 0)
        o.put("remotePad", a.remotePad)
        o.put("profileOverride", s.profileOverride?.rawValue ?? "auto")
        o.put("controlAa", s.handlebarControl)
        o.put("forceNonTouch", s.forceNonTouch)
        o.put("forceTouch", s.forceTouch)
        o.put("wifiTransport", s.wifiTransport.rawValue)
        let m = s.screenMargins
        var margins = OrderedJSONObject()
        margins.put("customised", m.customised)
        margins.put("top", m.customised ? m.top : 0)
        margins.put("bottom", m.customised ? m.bottom : 0)
        margins.put("left", m.customised ? m.left : 0)
        margins.put("right", m.customised ? m.right : 0)
        o.put("screenMargins", margins)
        var buttons = OrderedJSONObject()
        for g in ButtonGesture.allCases {
            buttons.put(g.rawValue, (s.buttonMap[g] ?? g.defaultAction).rawValue)
        }
        o.put("buttons", buttons)
        o.put(IOSKey.keepScreenOn, s.keepScreenOn)
        root.put("settings", o)
        return root
    }

    /// The pack text exactly as Android writes it (`toString(2)`, `/` escaped, no trailing newline).
    public static func exportJSON(settings: BikeSettings, androidOnly: AndroidOnlySettings,
                                  profileName: String, appVersion: String,
                                  date: Date = Date(), timeZone: TimeZone = .current) -> String {
        AndroidOrgJSON.pretty(.object(exportObject(settings: settings, androidOnly: androidOnly, profileName: profileName,
                                                   appVersion: appVersion, date: date, timeZone: timeZone)),
                              indentSpaces: 2)
    }

    /// Exports the tuning of a bike from a store (per-bike values resolved for `bikeId`).
    public static func exportJSON(from store: SettingsStore, bikeId: String?, profileName: String,
                                  appVersion: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        exportJSON(settings: store.settings(forBike: bikeId), androidOnly: store.androidOnlySettings(forBike: bikeId),
                   profileName: profileName, appVersion: appVersion, date: date, timeZone: timeZone)
    }

    // MARK: - Import

    public struct ImportResult: Sendable, Equatable {
        public var ok: Bool
        /// Verbatim Android message (English).
        public var message: String
        public init(ok: Bool, message: String) { self.ok = ok; self.message = message }
    }

    /// Validates a pack without applying it: returns the `settings` object or a failed result with the
    /// Android message (`Not valid JSON: …`, `Not an OpenCfMoto settings file (format=…)`,
    /// `Unsupported settings version … (this app reads 1…1)`, `Missing settings object`).
    static func validate(_ text: String) -> (root: OrderedJSONObject, settings: OrderedJSONObject)? {
        if case let .success(v) = validated(text) { return v }
        return nil
    }

    /// Real packs are a few KiB; anything bigger is refused before parsing (review SEC-4).
    static let maxPackBytes = 1 << 20

    private static func validated(_ text: String) -> Result<(root: OrderedJSONObject, settings: OrderedJSONObject), ImportFailure> {
        let size = text.utf8.count
        guard size <= maxPackBytes else {
            return .failure(ImportFailure(message: "Not valid JSON: file too large (\(size) bytes)"))
        }
        var t = AppJvmText.trim(text)
        if t.unicodeScalars.first == "\u{FEFF}" { t = String(Substring(t.unicodeScalars.dropFirst())) }
        let root: OrderedJSONObject
        do {
            root = try AndroidOrgJSON.parseObject(t)
        } catch {
            return .failure(ImportFailure(message: "Not valid JSON: \(error)"))
        }
        let fmt = root.orgOptString("format", "")
        if fmt != format {
            return .failure(ImportFailure(message: "Not an OpenCfMoto settings file (format=\(fmt))"))
        }
        let ver = Int(root.orgOptInt("version", 0))
        if ver < 1 || ver > version {
            return .failure(ImportFailure(message: "Unsupported settings version \(ver) (this app reads 1\u{2026}\(version))"))
        }
        guard let s = root.orgOptObject("settings") else {
            return .failure(ImportFailure(message: "Missing settings object"))
        }
        return .success((root, s))
    }

    private struct ImportFailure: Error { let message: String }

    /// Imports a pack (Android `importJSON`): per-bike values go to `bikeId` (the selected garage bike;
    /// nil → global keys), global ones change for all bikes. Apply order: `videoQuality`, `screenFit`,
    /// `mirrorOrientation`, `powerMode`, `resolutionMode` (exact enum names; invalid ones silently
    /// skipped), `aaDpiOverride`, `remotePad`, `profileOverride` (unknown id → automatic), `controlAa`,
    /// `forceNonTouch`, `forceTouch` (later wins), `wifiTransport` (unknown → auto), `screenMargins`
    /// (`customised` true → set clamped edges, else reset), `buttons` (unknown actions skipped), then
    /// the iOS keys. Personal prefs in older packs are ignored. `bikeName` is used in the message
    /// (`selected bike` when nil).
    public static func importJSON(_ text: String, into store: SettingsStore, bikeId: String?, bikeName: String?) -> ImportResult {
        let root: OrderedJSONObject
        let s: OrderedJSONObject
        switch validated(text) {
        case let .failure(f): return ImportResult(ok: false, message: f.message)
        case let .success(v): (root, s) = v
        }

        apply(s, to: store, bikeId: bikeId)

        let hint = root.orgOptObject("bikeHint")
        func usable(_ v: String?) -> String? {
            guard let v, !AppJvmText.isBlank(v), v != "null" else { return nil }
            return v
        }
        let profile = usable(hint?.orgOptString("profile")) ?? usable(hint?.orgOptString("profileOverride"))
        let onto = bikeName ?? "selected bike"
        let msg = profile.map { "Imported bike tuning (\($0)) onto \(onto)" } ?? "Bike tuning imported onto \(onto)"
        return ImportResult(ok: true, message: msg)
    }

    private static func apply(_ s: OrderedJSONObject, to store: SettingsStore, bikeId b: String?) {
        func name(_ key: String) -> String? {
            let v = s.orgOptString(key)
            return AppJvmText.isBlank(v) ? nil : v
        }
        if let v = name("videoQuality").flatMap(VideoQuality.init(rawValue:)) { store.setVideoQuality(v, forBike: b) }
        if let v = name("screenFit").flatMap(ScreenFit.init(rawValue:)) { store.setScreenFit(v, forBike: b) }
        if let v = name("mirrorOrientation").flatMap(MirrorOrientation.init(rawValue:)) { store.setMirrorOrientation(v, forBike: b) }
        if let v = name("powerMode").flatMap(PowerMode.init(rawValue:)) { store.setPowerMode(v, forBike: b) }
        if let v = name("resolutionMode").flatMap(AndroidAutoResolutionMode.init(rawValue:)) { store.setResolutionMode(v, forBike: b) }
        if s.orgHas("aaDpiOverride") { store.setAaDpiOverride(Int(s.orgOptInt("aaDpiOverride", 0)), forBike: b) }
        if s.orgHas("remotePad") { store.setRemotePad(s.orgOptBoolean("remotePad")) }
        if s.orgHas("profileOverride") {
            let id = s.orgOptString("profileOverride")
            store.setProfileOverride(id == "auto" ? nil : BikeProfileID(rawValue: id), forBike: b)
        }
        if s.orgHas("controlAa") { store.setHandlebarControl(s.orgOptBoolean("controlAa"), forBike: b) }
        if s.orgHas("forceNonTouch") { store.setForceNonTouch(s.orgOptBoolean("forceNonTouch")) }
        if s.orgHas("forceTouch") { store.setForceTouch(s.orgOptBoolean("forceTouch")) }
        if s.orgHas("wifiTransport") { store.setWifiTransport(WifiTransport(rawValue: s.orgOptString("wifiTransport")) ?? .auto) }
        if let m = s.orgOptObject("screenMargins") {
            if m.orgOptBoolean("customised") {
                store.setScreenMargins(top: Int(m.orgOptInt("top")), bottom: Int(m.orgOptInt("bottom")),
                                       left: Int(m.orgOptInt("left")), right: Int(m.orgOptInt("right")))
            } else {
                store.resetScreenMargins()
            }
        }
        if let buttons = s.orgOptObject("buttons") {
            for g in ButtonGesture.allCases where buttons.orgHas(g.rawValue) {
                if let a = ButtonAction(rawValue: buttons.orgOptString(g.rawValue)) {
                    store.setButtonAction(a, for: g, forBike: b)
                }
            }
        }
        // iOS-only keys
        if s.orgHas(IOSKey.keepScreenOn) {
            let on = s.orgOptBoolean(IOSKey.keepScreenOn)
            store.update(forBike: b) { $0.keepScreenOn = on }
        }
    }
}
