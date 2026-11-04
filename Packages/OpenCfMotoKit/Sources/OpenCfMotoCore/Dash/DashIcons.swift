// SPDX-License-Identifier: AGPL-3.0-or-later AND Apache-2.0
// Ported from OpenCfMoto (Android) res/drawable/ic_man_*.xml, ic_fab_*.xml, ic_search.xml,
// ic_nav_arrow.xml, ic_dest_pin.xml — docs/spec/navigation-dash.md §11.5.
// Path data is copied verbatim from the vector drawables; Android `rotation` groups are clockwise
// about the pivot in a y-down space (identical to `DashTransform.rotation`).
//
// Material Icons by Google, licensed under the Apache License, Version 2.0
// (LICENSES/Apache-2.0.txt), reach this file through those drawables: .fabGps (gps_fixed), .fabPlus
// (add), .fabMinus (remove), .fabMenu (more_vert), .fabFit (crop_free), .fabVoice (volume_up) and
// .search (search) carry the icons' path data unchanged; .fabCompass is explore with a smaller
// needle and .manArrive is place (location_on) with its dot drawn as two arcs. The other icons are
// OpenCfMoto's own geometry (the Apple Music ones were drawn for this port).

import Foundation

/// Every vector icon drawn by the dash UI (Android drawable names as raw values).
public enum DashIcon: String, CaseIterable, Sendable {
    case manStraight = "ic_man_straight"
    case manSlightRight = "ic_man_slight_right"
    case manRight = "ic_man_right"
    case manSharpRight = "ic_man_sharp_right"
    case manSlightLeft = "ic_man_slight_left"
    case manLeft = "ic_man_left"
    case manSharpLeft = "ic_man_sharp_left"
    case manUturn = "ic_man_uturn"
    case manRoundabout = "ic_man_roundabout"
    case manMerge = "ic_man_merge"
    case manFork = "ic_man_fork"
    case manArrive = "ic_man_arrive"
    case fabGps = "ic_fab_gps"
    case fabPlus = "ic_fab_plus"
    case fabMinus = "ic_fab_minus"
    case fabCompass = "ic_fab_compass"
    case fabMenu = "ic_fab_menu"
    case fabFit = "ic_fab_fit"
    case fabVoice = "ic_fab_voice"
    case search = "ic_search"
    /// The rider puck (48×48 viewport): shadow disc + blue chevron + white inner chevron.
    case navArrow = "ic_nav_arrow"
    /// Destination / saved-place teardrop (40×48 viewport), anchor = bottom centre (20,48).
    case destPin = "ic_dest_pin"
    // Apple Music (iOS addition; original simple geometry, 24×24, filled).
    /// Two beamed notes: artwork placeholder.
    case musicNote = "ic_music_note"
    case play = "ic_play"
    case pause = "ic_pause"
    case skipNext = "ic_skip_next"
    case skipPrevious = "ic_skip_previous"
    case close = "ic_close"
}

/// One painted layer of an icon, in viewport coordinates.
public struct DashIconLayer: Sendable, Equatable {
    public enum Paint: Sendable, Equatable {
        case fill(DashColor, DashFillRule)
        case stroke(DashColor, width: Double, cap: DashLineCap, join: DashLineJoin)
    }
    public var path: DashPath
    public var paint: Paint
    public init(path: DashPath, paint: Paint) { self.path = path; self.paint = paint }
}

/// An icon as layers in its own viewport (24×24, 48×48 or 40×48).
public struct DashIconDrawing: Sendable, Equatable {
    public var viewport: DashSize
    public var layers: [DashIconLayer]
    public init(viewport: DashSize, layers: [DashIconLayer]) { self.viewport = viewport; self.layers = layers }
}

/// Icon factories: path data → `DashIconDrawing`, aspect-fit into a target rect.
public enum DashIcons {
    /// Base maneuver arrow (filled): head triangle (5,12)-(12,3)-(19,12), shaft x 10…14, y 12…21.
    public static let baseArrowPathData = "M12,3 L19,12 L14,12 L14,21 L10,21 L10,12 L5,12 Z"

    static let pathData: [DashIcon: [String]] = [
        // Apple Music (iOS addition): original geometry, no third-party path data.
        .musicNote: ["M9,3.5 L20,1.5 L20,16 A3,3 0 1 1 18,13.2 L18,5.2 L11,6.5 L11,18 A3,3 0 1 1 9,15.2 Z"],
        .play: ["M8,5 L19,12 L8,19 Z"],
        .pause: ["M6,5 L10,5 L10,19 L6,19 Z M14,5 L18,5 L18,19 L14,19 Z"],
        .skipNext: ["M5,6 L14,12 L5,18 Z M16,6 L19,6 L19,18 L16,18 Z"],
        .skipPrevious: ["M19,6 L10,12 L19,18 Z M5,6 L8,6 L8,18 L5,18 Z"],
        .close: ["M6.4,5 L12,10.6 L17.6,5 L19,6.4 L13.4,12 L19,17.6 L17.6,19 L12,13.4 L6.4,19 L5,17.6 L10.6,12 L5,6.4 Z"],
        .manUturn: ["M8,20 L8,11 A4,4 0 0 1 16,11 L16,15", "M12.5,14 L19.5,14 L16,19 Z"],
        .manRoundabout: ["M12,21 L12,15 M12,15 m-4,0 a4,4 0 1,0 8,0 a4,4 0 1,0 -8,0", "M16,11 L16,4", "M13,6 L16,2 L19,6 Z"],
        .manMerge: ["M7,21 L7,14 Q7,11 10,10 L13,8.5 M13,8.5 L13,21", "M9.5,10.5 L13,5 L16.5,10.5 Z"],
        .manFork: ["M12,21 L12,13 M12,13 L7,8 M12,13 L17,8", "M4.5,9.5 L7,4 L9.5,9.5 Z", "M14.5,9.5 L17,4 L19.5,9.5 Z"],
        .manArrive: ["M12,2 C8.13,2 5,5.13 5,9 C5,14.25 12,22 12,22 C12,22 19,14.25 19,9 C19,5.13 15.87,2 12,2 Z M12,11.5 A2.5,2.5 0 1 1 12,6.5 A2.5,2.5 0 1 1 12,11.5 Z"],
        .fabGps: ["M12,8c-2.21,0 -4,1.79 -4,4s1.79,4 4,4 4,-1.79 4,-4 -1.79,-4 -4,-4zM20.94,11c-0.46,-4.17 -3.77,-7.48 -7.94,-7.94V1h-2v2.06C6.83,3.52 3.52,6.83 3.06,11H1v2h2.06c0.46,4.17 3.77,7.48 7.94,7.94V23h2v-2.06c4.17,-0.46 7.48,-3.77 7.94,-7.94H23v-2h-2.06zM12,19c-3.87,0 -7,-3.13 -7,-7s3.13,-7 7,-7 7,3.13 7,7 -3.13,7 -7,7z"],
        .fabPlus: ["M19,13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"],
        .fabMinus: ["M19,13H5v-2h14v2z"],
        .fabCompass: ["M12,2C6.48,2 2,6.48 2,12s4.48,10 10,10 10,-4.48 10,-10S17.52,2 12,2zM14.14,14.14L9,15l0.86,-5.14L15,9l-0.86,5.14z"],
        .fabMenu: ["M12,8c1.1,0 2,-0.9 2,-2s-0.9,-2 -2,-2 -2,0.9 -2,2 0.9,2 2,2zM12,10c-1.1,0 -2,0.9 -2,2s0.9,2 2,2 2,-0.9 2,-2 -0.9,-2 -2,-2zM12,16c-1.1,0 -2,0.9 -2,2s0.9,2 2,2 2,-0.9 2,-2 -0.9,-2 -2,-2z"],
        .fabFit: ["M3,5v4h2V5h4V3H5c-1.1,0 -2,0.9 -2,2zM5,15H3v4c0,1.1 0.9,2 2,2h4v-2H5v-4zM19,19h-4v2h4c1.1,0 2,-0.9 2,-2v-4h-2v4zM19,3h-4v2h4v4h2V5c0,-1.1 -0.9,-2 -2,-2z"],
        .fabVoice: ["M3,9v6h4l5,5V4L7,9H3zM16.5,12c0,-1.77 -1.02,-3.29 -2.5,-4.03v8.05c1.48,-0.73 2.5,-2.25 2.5,-4.02zM14,3.23v2.06c2.89,0.86 5,3.54 5,6.71s-2.11,5.85 -5,6.71v2.06c4.01,-0.91 7,-4.49 7,-8.77s-2.99,-7.86 -7,-8.77z"],
        .search: ["M15.5,14h-0.79l-0.28,-0.27C15.41,12.59 16,11.11 16,9.5 16,5.91 13.09,3 9.5,3S3,5.91 3,9.5 5.91,16 9.5,16c1.61,0 3.09,-0.59 4.23,-1.57l0.27,0.28v0.79l5,4.99L20.49,19l-4.99,-5zM9.5,14C7.01,14 5,11.99 5,9.5S7.01,5 9.5,5 14,7.01 14,9.5 11.99,14 9.5,14z"],
        .navArrow: ["M24,24m-15,0a15,15 0,1 1,30 0a15,15 0,1 1,-30 0", "M24,6 L38,36 L24,30 L10,36 Z", "M24,10 L33,32 L24,27.5 L15,32 Z"],
        .destPin: ["M20,0C11.16,0 4,7.16 4,16c0,12 16,32 16,32s16,-20 16,-32C36,7.16 28.84,0 20,0z", "M20,10c-3.31,0 -6,2.69 -6,6s2.69,6 6,6 6,-2.69 6,-6 -2.69,-6 -6,-6z"],
    ]

    /// Clockwise rotation (degrees, about (12,12)) of the base arrow for the arrow-style maneuvers.
    public static func arrowRotationDeg(_ icon: DashIcon) -> Double? {
        switch icon {
        case .manStraight: return 0
        case .manSlightRight: return 45
        case .manRight: return 90
        case .manSharpRight: return 135
        case .manSlightLeft: return -45
        case .manLeft: return -90
        case .manSharpLeft: return -135
        default: return nil
        }
    }

    /// `iconResFor(dir)` (GpxNav.kt): MERGE_*/FORK_* share one icon, STRAIGHT/CONTINUE share one.
    public static func icon(for dir: TurnDir) -> DashIcon {
        switch dir {
        case .left: return .manLeft
        case .right: return .manRight
        case .sharpLeft: return .manSharpLeft
        case .sharpRight: return .manSharpRight
        case .slightLeft: return .manSlightLeft
        case .slightRight: return .manSlightRight
        case .uturn: return .manUturn
        case .roundabout: return .manRoundabout
        case .mergeLeft, .mergeRight: return .manMerge
        case .forkLeft, .forkRight: return .manFork
        case .straight, .continue: return .manStraight
        case .arrive: return .manArrive
        }
    }

    private static func parsed(_ s: String) -> DashPath { (try? DashPath(svg: s)) ?? DashPath() }

    private static func build(_ icon: DashIcon) -> DashIconDrawing {
        let white = DashColor.white
        let vp24 = DashSize(width: 24, height: 24)
        if let deg = arrowRotationDeg(icon) {
            let rot = DashTransform.translation(-12, -12)
                .concatenating(.rotation(deg * .pi / 180))
                .concatenating(.translation(12, 12))
            return DashIconDrawing(viewport: vp24, layers: [
                DashIconLayer(path: parsed(baseArrowPathData).applying(rot), paint: .fill(white, .nonZero)),
            ])
        }
        let d = pathData[icon] ?? []
        func p(_ i: Int) -> DashPath { parsed(d[i]) }
        switch icon {
        case .manUturn:
            return DashIconDrawing(viewport: vp24, layers: [
                DashIconLayer(path: p(0), paint: .stroke(white, width: 2.4, cap: .round, join: .round)),
                DashIconLayer(path: p(1), paint: .fill(white, .nonZero)),
            ])
        case .manRoundabout:
            // strokeLineJoin not set in the XML → Android default (miter).
            return DashIconDrawing(viewport: vp24, layers: [
                DashIconLayer(path: p(0), paint: .stroke(white, width: 2.2, cap: .round, join: .miter)),
                DashIconLayer(path: p(1), paint: .stroke(white, width: 2.2, cap: .round, join: .miter)),
                DashIconLayer(path: p(2), paint: .fill(white, .nonZero)),
            ])
        case .manMerge:
            return DashIconDrawing(viewport: vp24, layers: [
                DashIconLayer(path: p(0), paint: .stroke(white, width: 2.2, cap: .round, join: .round)),
                DashIconLayer(path: p(1), paint: .fill(white, .nonZero)),
            ])
        case .manFork:
            return DashIconDrawing(viewport: vp24, layers: [
                DashIconLayer(path: p(0), paint: .stroke(white, width: 2.2, cap: .round, join: .round)),
                DashIconLayer(path: p(1), paint: .fill(white, .nonZero)),
                DashIconLayer(path: p(2), paint: .fill(white, .nonZero)),
            ])
        case .manArrive:
            // Map pin with a hole: even-odd keeps the hole regardless of sub-path winding.
            return DashIconDrawing(viewport: vp24, layers: [DashIconLayer(path: p(0), paint: .fill(white, .evenOdd))])
        case .fabCompass:
            return DashIconDrawing(viewport: vp24, layers: [DashIconLayer(path: p(0), paint: .fill(white, .evenOdd))])
        case .fabGps, .fabPlus, .fabMinus, .fabMenu, .fabFit, .fabVoice, .search,
             .musicNote, .play, .pause, .skipNext, .skipPrevious, .close:
            return DashIconDrawing(viewport: vp24, layers: [DashIconLayer(path: p(0), paint: .fill(white, .nonZero))])
        case .navArrow:
            return DashIconDrawing(viewport: DashSize(width: 48, height: 48), layers: [
                DashIconLayer(path: p(0), paint: .fill(DashPalette.puckShadow, .nonZero)),
                DashIconLayer(path: p(1), paint: .fill(DashPalette.puckBlue, .nonZero)),
                DashIconLayer(path: p(2), paint: .fill(DashPalette.puckWhite, .nonZero)),
            ])
        case .destPin:
            return DashIconDrawing(viewport: DashSize(width: 40, height: 48), layers: [
                DashIconLayer(path: p(0), paint: .fill(DashPalette.pinRed, .nonZero)),
                DashIconLayer(path: p(1), paint: .fill(DashPalette.pinInner, .nonZero)),
            ])
        default:
            return DashIconDrawing(viewport: vp24, layers: [])
        }
    }

    private static let cache: [DashIcon: DashIconDrawing] = {
        var out: [DashIcon: DashIconDrawing] = [:]
        for icon in DashIcon.allCases { out[icon] = build(icon) }
        return out
    }()

    /// The icon's layers in viewport coordinates (white glyphs unless the icon has its own colours).
    public static func drawing(_ icon: DashIcon) -> DashIconDrawing {
        cache[icon] ?? DashIconDrawing(viewport: DashSize(width: 24, height: 24), layers: [])
    }

    /// Aspect-fit (centred) transform from an icon viewport into `rect`, optionally rotated by
    /// `rotation` radians (clockwise) about the rect centre. Returns the transform and the scale.
    public static func fitTransform(viewport: DashSize, into rect: DashRect, rotation: Double = 0) -> (transform: DashTransform, scale: Double) {
        guard viewport.width > 0, viewport.height > 0 else { return (.identity, 1) }
        let s = min(rect.width / viewport.width, rect.height / viewport.height)
        var t = DashTransform.translation(-viewport.width / 2, -viewport.height / 2)
            .concatenating(.scale(s, s))
        if rotation != 0 { t = t.concatenating(.rotation(rotation)) }
        t = t.concatenating(.translation(rect.midX, rect.midY))
        return (t, s)
    }

    /// The icon's paths (all layers merged) aspect-fitted into `rect`.
    public static func path(_ icon: DashIcon, in rect: DashRect, rotation: Double = 0) -> DashPath {
        let d = drawing(icon)
        let (t, _) = fitTransform(viewport: d.viewport, into: rect, rotation: rotation)
        var out = DashPath()
        for l in d.layers { out.append(l.path.applying(t)) }
        return out
    }

    /// Draw commands for an icon aspect-fitted into `rect`.
    /// - Parameters:
    ///   - tint: replaces every layer colour (alpha = layer alpha × tint alpha), like Android `tint`.
    ///   - alpha: overall opacity multiplier (e.g. 0.55 for the compass FAB in north-up).
    ///   - rotation: radians, clockwise, about the rect centre (compass needle, puck).
    public static func commands(_ icon: DashIcon, in rect: DashRect, tint: DashColor? = nil, alpha: Double = 1,
                                rotation: Double = 0) -> [DashDrawCommand] {
        let d = drawing(icon)
        let (t, s) = fitTransform(viewport: d.viewport, into: rect, rotation: rotation)
        func color(_ c: DashColor) -> DashColor {
            let base = tint.map { $0.withAlpha($0.alpha * c.alpha) } ?? c
            return alpha >= 1 ? base : base.withAlpha(base.alpha * max(0, alpha))
        }
        return d.layers.map { l in
            let p = l.path.applying(t)
            switch l.paint {
            case let .fill(c, rule):
                return .fill(p, color(c), rule)
            case let .stroke(c, width, cap, join):
                return .stroke(p, DashStroke(width: width * s, color: color(c), cap: cap, join: join))
            }
        }
    }
}
