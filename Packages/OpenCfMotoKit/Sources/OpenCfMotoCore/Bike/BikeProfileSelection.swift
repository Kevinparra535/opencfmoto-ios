// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) BikeProfile.kt (BikeProfiles), ProfileOverride.kt,
// DashMemory.kt (bestFit) and PxcHandshake.kt (keep-landscape refinement)
//
// Profile selection (docs/spec/control-plane.md §12.2, §12.5):
// - authoritative from CLIENT_INFO: manual override, else the highest positive score, first in
//   registry order wins ties, none → Legacy;
// - early from the QR (before connecting), optionally wrapped with the learned panel;
// - refinement when CLIENT_INFO arrives: keep a wide early profile instead of 800NK Advanced.

import Foundation

public enum BikeProfiles {
    /// Registry in tie-break order (`maxByOrNull` keeps the FIRST maximum).
    public static let registry: [BikeProfile] = [
        .nk800, .nkAdvanced, .morini, .motoplayLandscape, .clc450, .cfdl26Landscape, .cfdl26Portrait, .legacy,
    ]

    /// Universal fallback.
    public static var legacy: BikeProfile { .legacy }

    /// Every profile's score for a CLIENT_INFO, in registry order.
    public static func scores(for info: BikeClientInfo) -> [(profile: BikeProfile, score: Int)] {
        registry.map { ($0, $0.score(info)) }
    }

    /// `[profile] scores=<name>=<score>, …` (Android log format).
    public static func scoresDescription(for info: BikeClientInfo) -> String {
        "[profile] scores=" + scores(for: info).map { "\($0.profile.name)=\($0.score)" }.joined(separator: ", ")
    }

    /// Authoritative selection from CLIENT_INFO (`BikeProfiles.select`).
    /// - Parameter override: manual Setup override (nil = automatic).
    public static func select(info: BikeClientInfo, override: BikeProfileID?, log: Bool = true) -> BikeProfile {
        if let override {
            let p = BikeProfile.profile(override)
            if log { Log.i("LINK", "[profile] manual override → \(p.name)") }
            return p
        }
        let scored = scores(for: info)
        if log { Log.i("LINK", "[profile] scores=" + scored.map { "\($0.profile.name)=\($0.score)" }.joined(separator: ", ")) }
        var best: (profile: BikeProfile, score: Int)?
        for entry in scored where entry.score > 0 {
            if best == nil || entry.score > best!.score { best = entry }
        }
        return best?.profile ?? .legacy
    }

    /// Early selection from the pairing QR (`selectByQr`): override → QR guess → learned-panel
    /// wrapper. `learnedCanvas` is the canvas remembered for this QR's SSID (its REQUESTED size is
    /// the raw panel Android stores in `dash_geo_<ssid>`); ignored when `qr` is nil.
    public static func selectByQR(_ qr: BikeQR?, override: BikeProfileID?, learnedCanvas: VideoCanvas? = nil) -> BikeProfile {
        if let override { return BikeProfile.profile(override) }
        let base = qrGuess(qr)
        guard qr != nil, let learned = learnedCanvas else { return base }
        let w = learned.requestedWidth, h = learned.requestedHeight
        guard (1 ... 8192).contains(w), (1 ... 8192).contains(h) else { return base }
        let panel = BikeProfile.PanelSize(width: w, height: h)
        if panel == base.panelSize { return base }
        guard learnedGeometryFit(width: w, height: h) != nil else { return base }
        Log.i("LINK", "[panel] using measured \(w)x\(h) (was \(base.name))")
        return base.withMeasuredPanel(panel)
    }

    /// The QR guess without learned geometry (`selectByQrGuess`).
    public static func qrGuess(_ qr: BikeQR?) -> BikeProfile {
        guard let qr else { return .legacy }
        let ssidUpper = qr.ssid.uppercased()
        if ssidUpper.hasPrefix("MLN_") || (ssidUpper.hasPrefix("ML") && ["21333", "00297"].contains(qr.modelId ?? "")) {
            return .morini
        }
        let matches = registry.filter { $0.matchesModelId(qr.modelId ?? "") }
        if matches.isEmpty { return .legacy }
        if matches.count == 1 { return matches[0] }
        // modelId 37426 is shared by 1000 MT-X (P2P/portrait), 800MT (AP/landscape) and 800NK Advanced:
        // P2P → portrait, otherwise the safer landscape (never NK Advanced from the QR).
        let isP2p = qr.supportsP2p || qr.ssid.hasPrefix("DIRECT-")
        return isP2p ? .cfdl26Portrait : .cfdl26Landscape
    }

    /// First registry profile claiming a QR modelId, else Legacy (`selectByModelId`, tests only).
    public static func selectByModelId(_ modelId: String?) -> BikeProfile {
        guard let modelId else { return .legacy }
        return registry.first { $0.matchesModelId(modelId) } ?? .legacy
    }

    /// Keep-landscape refinement (`PxcHandshake.kt:149-166`): if the early (QR / learned) profile's
    /// panel is wide (`w >= h*3/2`) and CLIENT_INFO picked 800NK Advanced, keep the early profile.
    public static func refine(early: BikeProfile, selected: BikeProfile) -> BikeProfile {
        if let panel = early.panelSize, panel.isWide, selected.id == .nkAdvanced, !selected.isLearnedGeometry {
            return early
        }
        return selected
    }

    /// `DashMemory.bestFit`: an Android Auto size holding the 16-rounded panel at 1:1 on one axis
    /// (one axis equal, the other ≥), minimising `(rw−cw)(rh−ch) + (rw−cw) + (rh−ch)`; nil if none.
    /// Only used to decide whether a learned panel wraps the QR profile (Android parity).
    public static func learnedGeometryFit(width: Int, height: Int) -> (width: Int, height: Int)? {
        let cw = width & 0xFFF0, ch = height & 0xFFF0
        let candidates = [(800, 480), (1280, 720), (720, 1280), (1080, 1920)]
        let exact = candidates.filter { r in (r.0 == cw && r.1 >= ch) || (r.1 == ch && r.0 >= cw) }
        var best: (Int, Int)?
        var bestCost = Int64.max
        for r in exact {
            let cost = Int64(r.0 - cw) * Int64(r.1 - ch) + Int64(r.0 - cw) + Int64(r.1 - ch)
            if cost < bestCost {
                bestCost = cost
                best = r
            }
        }
        return best.map { (width: $0.0, height: $0.1) }
    }

    // MARK: Manual override ids

    /// Setup override ids, in Android order, plus the two iOS-only ids. "auto" means nil.
    public static let overrideIds: [String] = ["auto"] + BikeProfileID.allCases.map(\.rawValue)

    /// Parses a persisted override id: "auto", nil or unknown ids → nil (automatic), like
    /// `ProfileOverride.byId`.
    public static func overrideID(from id: String?) -> BikeProfileID? {
        guard let id, id != "auto" else { return nil }
        return BikeProfileID(rawValue: id)
    }

    /// Persisted form of an override (nil → "auto").
    public static func overrideString(_ id: BikeProfileID?) -> String { id?.rawValue ?? "auto" }
}
