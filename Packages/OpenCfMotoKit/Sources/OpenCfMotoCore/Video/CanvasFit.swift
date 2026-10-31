// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) AaCompositor.kt (computeViewport, mapCanvasToSource), ScreenMargins.kt
//
// FIT / FILL / STRETCH placement of a fixed-size source (ReplayKit mirror frames) inside the dash
// canvas minus the clamped screen margins (media-video.md §10.3–§10.4), with Android's exact math:
// Float32 aspects, Java `Math.round(float)`, truncating integer centring. All rects use ONE top-left
// canvas coordinate system (drawing, margins and touch) — Android's latent GL y-flip of `vy` is NOT
// reproduced. The own dash UI renders at canvas size and only uses the margins as unsafe insets.

import Foundation

/// An integer rectangle in canvas pixels (top-left origin). FILL viewports may extend beyond the
/// canvas (negative origin): clip to the canvas when drawing.
public struct CanvasViewport: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var dashRect: DashRect { DashRect(x: Double(x), y: Double(y), width: Double(width), height: Double(height)) }
    public var description: String { "\(x), \(y), \(width), \(height)" }
}

public enum CanvasFit {
    /// Per-profile default margins `[top, bottom, left, right]`: 800NK Advanced top 22, others 0.
    public static func profileDefaultMargins(_ profile: BikeProfileID?) -> ScreenMargins {
        profile == .nkAdvanced ? ScreenMargins(customised: false, top: 22) : ScreenMargins(customised: false)
    }

    /// The margins in effect: the rider's when customised, else the profile default
    /// (`ScreenMargins.top` etc. on Android). The result keeps `margins.customised`.
    public static func effectiveMargins(_ margins: ScreenMargins, profileDefault: ScreenMargins) -> ScreenMargins {
        guard !margins.customised else { return margins }
        return ScreenMargins(customised: false, top: profileDefault.top, bottom: profileDefault.bottom,
                             left: profileDefault.left, right: profileDefault.right)
    }

    /// English summary (`ScreenMargins.summary()`, problem reports):
    /// `None — Android Auto uses the whole dash` / `Top t · bottom b · left l · right r px[ (profile default)]`.
    public static func marginsSummary(_ margins: ScreenMargins, profileDefault: ScreenMargins) -> String {
        let m = effectiveMargins(margins, profileDefault: profileDefault)
        if m.top == 0 && m.bottom == 0 && m.left == 0 && m.right == 0 {
            return "None \u{2014} Android Auto uses the whole dash"
        }
        let s = "Top \(m.top) \u{00B7} bottom \(m.bottom) \u{00B7} left \(m.left) \u{00B7} right \(m.right) px"
        return margins.customised ? s : s + " (profile default)"
    }

    /// Margins clamped the way the compositor does: `T' = clamp(T, 0, H)`, `B' = clamp(B, 0, H − T')`,
    /// `L' = clamp(L, 0, W)`, `R' = clamp(R, 0, W − L')`.
    public static func clampedInsets(canvasWidth w: Int, canvasHeight h: Int, margins m: ScreenMargins)
        -> (top: Int, bottom: Int, left: Int, right: Int) {
        let t = min(max(m.top, 0), max(h, 0))
        let b = min(max(m.bottom, 0), max(h - t, 0))
        let l = min(max(m.left, 0), max(w, 0))
        let r = min(max(m.right, 0), max(w - l, 0))
        return (t, b, l, r)
    }

    /// The usable area (canvas minus clamped margins in effect; at least 1×1) — the own dash UI's
    /// safe area (paint the margins black and ignore touches there).
    public static func contentRect(canvasWidth w: Int, canvasHeight h: Int, margins: ScreenMargins) -> CanvasViewport {
        let c = clampedInsets(canvasWidth: w, canvasHeight: h, margins: margins)
        return CanvasViewport(x: c.left, y: c.top, width: max(w - c.left - c.right, 1), height: max(h - c.top - c.bottom, 1))
    }

    /// `AaCompositor.computeViewport`: where a `sourceWidth × sourceHeight` picture is drawn in the
    /// canvas for `mode`, inside the margins. nil when any dimension is 0. `margins` are the margins
    /// IN EFFECT (`effectiveMargins(_:profileDefault:)`); their `customised` flag is ignored here.
    /// Draw the picture into the returned rect, clipped to the canvas, on an opaque black background.
    public static func viewport(canvasWidth w: Int, canvasHeight h: Int, sourceWidth sw: Int, sourceHeight sh: Int,
                                mode: ScreenFit, margins: ScreenMargins = .zero) -> CanvasViewport? {
        guard w != 0, h != 0, sw != 0, sh != 0 else { return nil }
        let area = contentRect(canvasWidth: w, canvasHeight: h, margins: margins)
        let areaW = area.width, areaH = area.height
        let srcAspect = Float(sw) / Float(sh)
        let areaAspect = Float(areaW) / Float(areaH)
        var vw = areaW, vh = areaH
        switch mode {
        case .stretch:
            break
        case .fit:
            if srcAspect < areaAspect {
                vh = areaH; vw = Int(AppJavaNumber.roundFloat(Float(areaH) * srcAspect))
            } else {
                vw = areaW; vh = Int(AppJavaNumber.roundFloat(Float(areaW) / srcAspect))
            }
        case .fill:
            if srcAspect < areaAspect {
                vw = areaW; vh = Int(AppJavaNumber.roundFloat(Float(areaW) / srcAspect))
            } else {
                vh = areaH; vw = Int(AppJavaNumber.roundFloat(Float(areaH) * srcAspect))
            }
        }
        // Integer division truncates toward zero (FILL can be negative), like Kotlin.
        return CanvasViewport(x: area.x + (areaW - vw) / 2, y: area.y + (areaH - vh) / 2, width: vw, height: vh)
    }

    /// Convenience over a negotiated canvas.
    public static func viewport(canvas: VideoCanvas, sourceWidth: Int, sourceHeight: Int, mode: ScreenFit,
                                margins: ScreenMargins = .zero) -> CanvasViewport? {
        viewport(canvasWidth: canvas.width, canvasHeight: canvas.height, sourceWidth: sourceWidth,
                 sourceHeight: sourceHeight, mode: mode, margins: margins)
    }

    /// `AaCompositor.mapCanvasToSource`: a canvas point → source pixel, nil when it falls outside the
    /// drawn picture (black bar / margin). 64-bit integer math, truncating, clamped to the source.
    public static func mapCanvasToSource(x cx: Int, y cy: Int, viewport vp: CanvasViewport,
                                         sourceWidth sw: Int, sourceHeight sh: Int) -> (x: Int, y: Int)? {
        guard vp.width != 0, vp.height != 0, sw != 0, sh != 0 else { return nil }
        let rx = cx - vp.x
        let ry = cy - vp.y
        if rx < 0 || ry < 0 || rx >= vp.width || ry >= vp.height { return nil }
        let sx = Int(Int64(rx) * Int64(sw) / Int64(vp.width))
        let sy = Int(Int64(ry) * Int64(sh) / Int64(vp.height))
        return (min(max(sx, 0), sw - 1), min(max(sy, 0), sh - 1))
    }

    /// Whether a canvas point lies inside the content area (touches in the margins are ignored).
    public static func isInsideContent(x: Int, y: Int, canvasWidth: Int, canvasHeight: Int, margins: ScreenMargins) -> Bool {
        let r = contentRect(canvasWidth: canvasWidth, canvasHeight: canvasHeight, margins: margins)
        return x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height
    }
}
