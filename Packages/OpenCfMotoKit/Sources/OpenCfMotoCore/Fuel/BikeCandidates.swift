// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: «¿Cuál es tu moto?» candidates. The pairing QR's `modelid` names the DASH FAMILY, not the
// model (37416 is shared by several CFMOTO models), so the app recognises the family and asks the rider
// once with a short list; it preselects only when the family holds exactly one model.
//
// Family resolution, first match wins:
// 1. the learned canvas (REQ 16, `dash_geo_<ssid>`, rounded & 0xFFF0) when it is decisive on its own;
// 2. the live CLIENT_INFO winner of the running session, only when CORROBORATED (the QR modelId is claimed
//    by that family, or the CLIENT_INFO carries one of its markers) — the scoring has known quirks: any
//    unknown sdk-1.x dash wins 800NK Advanced, any non-touch sdk-0.9.x dash wins MotoPlay-66
//    (control-plane.md §12.6 cases I–L);
// 3. the persisted profile hint (the refined CLIENT_INFO profile of the last connect), skipped under a
//    per-bike profile override, and only when the QR modelId is claimed by it (legacy also with a CFMOTO
//    SSID or a live legacy marker) — legacy is the fallback for EVERY dash and is never trusted alone;
// 4. a QR modelId claimed by a registry profile (37426: P2P → portrait, else the 37426 ambiguity);
// 5. the Morini brand (SSID MLN_ / ML + 21333 / 00297, CLIENT_INFO flavor 51, a motomorini QR);
// 6. nothing → no candidates (search + manual entry).
// Whenever a rule yields 800MT landscape + 800NK Advanced (only the canvas separates them: an 800MT can
// score as NK Advanced), the list is `ambiguous37426`. No logging here.

import Foundation

/// What the stored data (and the running session, if any) say about a bike's dash.
public struct BikeSignals: Sendable, Equatable {
    /// BikeQR.modelId (trimmed).
    public var qrModelId: String?
    /// GarageBike.ssid.
    public var ssid: String?
    /// BikeQR.supportsP2p || ssid has the "DIRECT-" prefix.
    public var supportsP2p: Bool
    /// GarageBike.profileHint (refined profile of the last CLIENT_INFO).
    public var profileHint: BikeProfileID?
    /// The bike has a manual profile override (the hint then equals the override: not evidence).
    public var hasProfileOverride: Bool
    /// DashMemory.learnedSize(forSSID:).
    public var learnedCanvas: LearnedDashSize?
    /// Unrefined CLIENT_INFO winner of the RUNNING session (nil otherwise).
    public var liveWinner: BikeProfileID?
    /// Families whose markers the live CLIENT_INFO carries.
    public var liveMarkers: Set<BikeProfileID>
    /// Live CLIENT_INFO "flavor" (65540 CFMOTO, 51 Morini), nil when absent / 0.
    public var flavor: Int?
    /// The stored raw QR text contains "motomorini" (in memory only, never logged).
    public var moriniQR: Bool

    public init(qrModelId: String? = nil, ssid: String? = nil, supportsP2p: Bool = false, profileHint: BikeProfileID? = nil,
                hasProfileOverride: Bool = false, learnedCanvas: LearnedDashSize? = nil, liveWinner: BikeProfileID? = nil,
                liveMarkers: Set<BikeProfileID> = [], flavor: Int? = nil, moriniQR: Bool = false) {
        self.qrModelId = qrModelId
        self.ssid = ssid
        self.supportsP2p = supportsP2p
        self.profileHint = profileHint
        self.hasProfileOverride = hasProfileOverride
        self.learnedCanvas = learnedCanvas
        self.liveWinner = liveWinner
        self.liveMarkers = liveMarkers
        self.flavor = flavor
        self.moriniQR = moriniQR
    }
}

/// Which signal decided the family.
public enum DashFamilySource: String, Sendable, Equatable { case canvas, clientInfo, profileHint, qr, brand, none }

/// The ordered candidates for «¿Cuál es tu moto?».
public struct BikeCandidateList: Sendable, Equatable {
    /// [] = unknown; 2 entries only for the 37426 ambiguity.
    public var families: [BikeProfileID]
    public var source: DashFamilySource
    /// Ordered, de-duplicated, only ids present in the catalog.
    public var ids: [String]
    /// Prefilter for «Otra moto».
    public var brand: FuelBrand?
    public init(families: [BikeProfileID], source: DashFamilySource, ids: [String], brand: FuelBrand?) {
        self.families = families
        self.source = source
        self.ids = ids
        self.brand = brand
    }
    /// The row that starts selected: only when exactly one candidate remains.
    public var preselectedId: String? { ids.count == 1 ? ids[0] : nil }
}

public enum BikeCandidates {
    /// Family → ordered catalog ids (Latin-American commonness, the owner-confirmed 450MT first; of two tank
    /// variants the SMALLER tank first, so a rider who taps the first row errs on the safe side).
    public static let familyTable: [BikeProfileID: [String]] = [
        .legacy: ["cfmoto-450mt", "cfmoto-450sr", "cfmoto-450nk", "cfmoto-675nk", "cfmoto-675sr-r",
                  "cfmoto-700mt-18l", "cfmoto-700mt-20l", "cfmoto-300sr"],
        .motoplayLandscape: ["cfmoto-450sr", "cfmoto-450nk", "cfmoto-450mt", "cfmoto-675nk", "cfmoto-675sr-r",
                             "cfmoto-700mt-18l", "cfmoto-700mt-20l"],
        .clc450: ["cfmoto-450cl-c"],
        .nk800: ["cfmoto-800nk", "cfmoto-450nk"],
        .cfdl26Portrait: ["cfmoto-800mt-x", "cfmoto-1000mt-x"],
        .cfdl26Landscape: ["cfmoto-800mt-explore", "cfmoto-800mt"],
        .nkAdvanced: ["cfmoto-800nk-advanced"],
        .morini: ["motomorini-x-cape-650", "motomorini-x-cape-700", "motomorini-seiemmezzo"],
    ]

    /// A 37426 AP dash before its canvas is learned: 800MT landscape or 800NK Advanced (and an MT-X in AP
    /// mode — HUID 6WWV "800MT Explore / MT-X AP" — before its portrait canvas is learned, last).
    public static let ambiguous37426: [String] = ["cfmoto-800mt-explore", "cfmoto-800nk-advanced", "cfmoto-800mt",
                                                  "cfmoto-800mt-x", "cfmoto-1000mt-x"]

    /// Rows shown before «Ver más».
    public static let visibleBeforeMore = 4

    private static let ambiguousFamilies: [BikeProfileID] = [.cfdl26Landscape, .nkAdvanced]

    /// The family a learned panel identifies on its own, nil when not decisive (800×384 is shared by legacy
    /// and others and is also the encoder default before any REQ 16; 1280×720 decides nothing).
    public static func family(forCanvas size: LearnedDashSize) -> BikeProfileID? {
        let w = size.width & 0xFFF0, h = size.height & 0xFFF0
        if w == 720, (688 ... 720).contains(h) { return .nkAdvanced }
        if w == 1280, h == 576 { return .cfdl26Landscape }
        if w == 800, h > w { return .cfdl26Portrait }
        if w == 544, h == 512 { return .clc450 }
        if w == 1024, h == 464 { return .morini }
        if w == 800, h == 400 { return .motoplayLandscape }
        return nil
    }

    /// The families whose CLIENT_INFO markers are present (string rules as `BikeProfileScoring`).
    public static func liveMarkers(_ info: BikeClientInfo) -> Set<BikeProfileID> {
        let huid = info.optString("HUID")
        let huName = info.optString("HUName")
        let sdk = info.optString("sdkVersion")
        let versionName = info.optString("version_name")
        let pkg = info.optString("package_name")
        let channel = info.optString("channel")
        let carb = utf16HasPrefix(huid, "CARB", ignoreCase: true)
        var out = Set<BikeProfileID>()
        if utf16HasPrefix(huName, "CFDL16") || utf16HasPrefix(sdk, "0.9.29") || AppJvmText.trim(channel) == "37416" {
            out.insert(.legacy)
        }
        if utf16HasPrefix(huid, "CRCP") || (utf16HasPrefix(sdk, "0.9.23") && pkg == "linux_no_package") {
            out.insert(.nk800)
        }
        if utf16HasPrefix(huid, "6KWV") || utf16HasPrefix(versionName, "CFDL26") || pkg == "com.cfmoto.easyconnect" {
            out.insert(.nkAdvanced)
        }
        if BikeProfileScoring.looksCfmotoCfdl26(versionName: versionName, packageName: pkg), !carb {
            out.insert(.cfdl26Landscape)
            out.insert(.cfdl26Portrait)
        }
        if channel == "66660742" { out.insert(.motoplayLandscape) }
        if channel == "66660736" || huName.range(of: "48FB4C", options: .caseInsensitive) != nil { out.insert(.clc450) }
        if channel == "21333" || channel == "21322" || carb || info.optInt("flavor", 0) == 51 { out.insert(.morini) }
        return out
    }

    /// Builds the signals from the stored data (+ the running session's CLIENT_INFO, if any).
    public static func signals(qr: BikeQR?, bike: GarageBike?, hasProfileOverride: Bool,
                               learned: LearnedDashSize?, live: DashInfo?) -> BikeSignals {
        let modelId = qr?.modelId.map(AppJvmText.trim).flatMap { $0.isEmpty ? nil : $0 }
        let ssid = bike?.ssid ?? qr?.ssid
        var s = BikeSignals(qrModelId: modelId, ssid: ssid,
                            supportsP2p: (qr?.supportsP2p ?? false) || (ssid?.hasPrefix("DIRECT-") ?? false),
                            profileHint: bike?.profileHint, hasProfileOverride: hasProfileOverride, learnedCanvas: learned,
                            moriniQR: qr?.raw.lowercased().contains("motomorini") ?? false)
        if let live, let info = BikeClientInfo.parse(live.rawJSON) {
            var best: (id: BikeProfileID, score: Int)?
            for entry in BikeProfiles.scores(for: info) where entry.score > 0 {
                if best == nil || entry.score > best!.score { best = (entry.profile.id, entry.score) }
            }
            s.liveWinner = best?.id
            s.liveMarkers = liveMarkers(info)
            let flavor = info.optInt("flavor", 0)
            s.flavor = flavor == 0 ? nil : flavor
        }
        return s
    }

    /// The family list and its ordered candidate ids.
    public static func resolve(_ signals: BikeSignals, catalog: [FuelCatalogEntry] = FuelCatalog.all) -> BikeCandidateList {
        let (families, source) = familyOf(signals)
        let rawIds: [String]
        if families == ambiguousFamilies {
            rawIds = ambiguous37426
        } else {
            rawIds = families.flatMap { familyTable[$0] ?? [] }
        }
        let known = Set(catalog.map(\.id))
        var seen = Set<String>()
        let ids = rawIds.filter { known.contains($0) && seen.insert($0).inserted }
        let brand: FuelBrand?
        if families.contains(.morini) || source == .brand {
            brand = .morini
        } else if !families.isEmpty || (signals.ssid?.uppercased().hasPrefix("CFMOTO") ?? false) || signals.flavor == 65540 {
            brand = .cfmoto
        } else {
            brand = nil
        }
        return BikeCandidateList(families: families, source: source, ids: ids, brand: brand)
    }

    private static func familyOf(_ s: BikeSignals) -> ([BikeProfileID], DashFamilySource) {
        // 1. A decisive learned canvas.
        if let size = s.learnedCanvas, let f = family(forCanvas: size) { return ([f], .canvas) }
        // 2. The live winner, only when corroborated.
        if let w = s.liveWinner, claimedByQR(w, s) || s.liveMarkers.contains(w) {
            return (expandAmbiguity(w), .clientInfo)
        }
        // 3. The persisted hint (not under a per-bike override; legacy needs a CFMOTO SSID or a live marker
        //    when the modelId does not claim it).
        if !s.hasProfileOverride, let h = s.profileHint {
            let cfmotoSSID = s.ssid?.uppercased().hasPrefix("CFMOTO") ?? false
            if claimedByQR(h, s) || (h == .legacy && (cfmotoSSID || s.liveMarkers.contains(.legacy))) {
                return (expandAmbiguity(h), .profileHint)
            }
        }
        // 4. A modelId claimed by the registry.
        if let id = s.qrModelId {
            let matches = BikeProfiles.registry.filter { $0.matchesModelId(id) }
            if matches.count == 1 { return ([matches[0].id], .qr) }
            if matches.count > 1 { return (s.supportsP2p ? [.cfdl26Portrait] : ambiguousFamilies, .qr) }
        }
        // 5. The Morini brand (the same SSID rule as `BikeProfiles.qrGuess`).
        let ssidUpper = s.ssid?.uppercased() ?? ""
        if ssidUpper.hasPrefix("MLN_") || (ssidUpper.hasPrefix("ML") && ["21333", "00297"].contains(s.qrModelId ?? ""))
            || s.flavor == 51 || s.moriniQR {
            return ([.morini], .brand)
        }
        return ([], .none)
    }

    private static func claimedByQR(_ family: BikeProfileID, _ s: BikeSignals) -> Bool {
        guard let id = s.qrModelId else { return false }
        return BikeProfile.profile(family).matchesModelId(id)
    }

    private static func expandAmbiguity(_ f: BikeProfileID) -> [BikeProfileID] {
        f == .cfdl26Landscape || f == .nkAdvanced ? ambiguousFamilies : [f]
    }

    /// Kotlin `startsWith` over UTF-16 code units (ASCII case folding when `ignoreCase`).
    static func utf16HasPrefix(_ s: String, _ prefix: String, ignoreCase: Bool = false) -> Bool {
        let a = Array(s.utf16), p = Array(prefix.utf16)
        guard p.count <= a.count else { return false }
        for k in 0 ..< p.count {
            var x = a[k], y = p[k]
            if ignoreCase {
                if x >= 0x61, x <= 0x7A { x -= 0x20 }
                if y >= 0x61, y <= 0x7A { y -= 0x20 }
            }
            if x != y { return false }
        }
        return true
    }
}
