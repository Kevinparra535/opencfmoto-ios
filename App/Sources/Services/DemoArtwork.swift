// SPDX-License-Identifier: AGPL-3.0-or-later
// Album covers for the demo / E2E Music app (`-demoSeed`, `-e2eMusic`): drawn here with
// CoreGraphics and encoded as PNG with ImageIO — three palettes (a sunset road, a mountain pass, a
// night ride), gradients and simple shapes, no text and no third-party artwork. They exercise the
// dash's artwork path (DashImageStore → DashDrawCommand.image) exactly like a real cover.

import CoreGraphics
import Foundation
import ImageIO

enum DemoArtwork {
    private struct Palette {
        let skyTop: UInt32
        let skyBottom: UInt32
        let accent: UInt32
        let ground: UInt32
        let detail: UInt32
    }

    private static let palettes = [
        Palette(skyTop: 0xFF8A3D, skyBottom: 0x8E2D7B, accent: 0xFFE26A, ground: 0x1E1B2E, detail: 0x45405F),
        Palette(skyTop: 0x7FD8CB, skyBottom: 0x1D4E89, accent: 0xF4F1DE, ground: 0x14213D, detail: 0x2E5C8A),
        Palette(skyTop: 0x22355E, skyBottom: 0x05070F, accent: 0xE8E8F0, ground: 0x0B0F1C, detail: 0x3A86FF),
    ]

    private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Cover `index` (any integer; three designs repeat) as a `pixels` × `pixels` PNG.
    static func cover(_ index: Int, pixels: Int = 640) -> Data {
        let n = min(max(pixels, 16), 2_048)
        let design = ((index % 3) + 3) % 3
        let p = palettes[design]
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        let s = CGFloat(n)
        // CoreGraphics is y-up: y = 0 is the bottom of the cover.
        if let sky = CGGradient(colorsSpace: space, colors: [color(p.skyBottom), color(p.skyTop)] as CFArray,
                                locations: [0, 1]) {
            ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: s), options: [])
        }
        switch design {
        case 0: sunsetRoad(ctx, s, p)
        case 1: mountainPass(ctx, s, p)
        default: nightRide(ctx, s, p)
        }
        guard let image = ctx.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : Data()
    }

    private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [CGFloat((rgb >> 16) & 0xFF) / 255, CGFloat((rgb >> 8) & 0xFF) / 255,
                                                CGFloat(rgb & 0xFF) / 255, alpha])
            ?? CGColor(gray: 0.5, alpha: alpha)
    }

    private static func fill(_ ctx: CGContext, _ rgb: UInt32, alpha: CGFloat = 1, _ points: [CGPoint]) {
        guard let first = points.first else { return }
        ctx.beginPath()
        ctx.move(to: first)
        for pt in points.dropFirst() { ctx.addLine(to: pt) }
        ctx.closePath()
        ctx.setFillColor(color(rgb, alpha: alpha))
        ctx.fillPath()
    }

    /// A sun on the horizon and a straight road to it.
    private static func sunsetRoad(_ ctx: CGContext, _ s: CGFloat, _ p: Palette) {
        ctx.setFillColor(color(p.accent))
        ctx.fillEllipse(in: CGRect(x: s * 0.30, y: s * 0.36, width: s * 0.40, height: s * 0.40))
        ctx.setFillColor(color(p.ground))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.42))
        fill(ctx, p.detail, [CGPoint(x: s * 0.12, y: 0), CGPoint(x: s * 0.88, y: 0),
                             CGPoint(x: s * 0.53, y: s * 0.42), CGPoint(x: s * 0.47, y: s * 0.42)])
        // Centre line: dashes that shrink towards the horizon.
        var y: CGFloat = s * 0.02
        var h: CGFloat = s * 0.08
        while y < s * 0.40 {
            let t0 = y / (s * 0.42), t1 = min(1, (y + h) / (s * 0.42))
            let w0 = s * 0.018 * (1 - t0), w1 = s * 0.018 * (1 - t1)
            fill(ctx, p.accent, [CGPoint(x: s * 0.5 - w0, y: y), CGPoint(x: s * 0.5 + w0, y: y),
                                 CGPoint(x: s * 0.5 + w1, y: y + h), CGPoint(x: s * 0.5 - w1, y: y + h)])
            y += h * 1.8
            h *= 0.72
        }
    }

    /// Two mountain ridges with snow and a winding road.
    private static func mountainPass(_ ctx: CGContext, _ s: CGFloat, _ p: Palette) {
        fill(ctx, p.detail, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: s * 0.45), CGPoint(x: s * 0.28, y: s * 0.74),
                             CGPoint(x: s * 0.46, y: s * 0.55), CGPoint(x: s * 0.70, y: s * 0.84),
                             CGPoint(x: s, y: s * 0.50), CGPoint(x: s, y: 0)])
        fill(ctx, p.accent, [CGPoint(x: s * 0.70, y: s * 0.84), CGPoint(x: s * 0.62, y: s * 0.74),
                             CGPoint(x: s * 0.67, y: s * 0.76), CGPoint(x: s * 0.72, y: s * 0.73),
                             CGPoint(x: s * 0.78, y: s * 0.75)])
        fill(ctx, p.accent, [CGPoint(x: s * 0.28, y: s * 0.74), CGPoint(x: s * 0.22, y: s * 0.66),
                             CGPoint(x: s * 0.27, y: s * 0.68), CGPoint(x: s * 0.33, y: s * 0.67)])
        fill(ctx, p.ground, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: s * 0.30), CGPoint(x: s * 0.22, y: s * 0.42),
                             CGPoint(x: s * 0.50, y: s * 0.26), CGPoint(x: s * 0.80, y: s * 0.40),
                             CGPoint(x: s, y: s * 0.28), CGPoint(x: s, y: 0)])
        ctx.beginPath()
        ctx.move(to: CGPoint(x: s * 0.62, y: 0))
        ctx.addCurve(to: CGPoint(x: s * 0.50, y: s * 0.26), control1: CGPoint(x: s * 0.30, y: s * 0.08),
                     control2: CGPoint(x: s * 0.78, y: s * 0.18))
        ctx.setStrokeColor(color(p.accent, alpha: 0.9))
        ctx.setLineWidth(s * 0.03)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    /// A crescent moon, a few stars and a road curving into the dark.
    private static func nightRide(_ ctx: CGContext, _ s: CGFloat, _ p: Palette) {
        // Crescent: the moon disc minus an offset disc (even-odd clip), so the sky gradient shows through.
        ctx.saveGState()
        ctx.beginPath()
        ctx.addRect(CGRect(x: 0, y: 0, width: s, height: s))
        ctx.addEllipse(in: CGRect(x: s * 0.67, y: s * 0.68, width: s * 0.22, height: s * 0.22))
        ctx.clip(using: .evenOdd)
        ctx.setFillColor(color(p.accent))
        ctx.fillEllipse(in: CGRect(x: s * 0.62, y: s * 0.64, width: s * 0.22, height: s * 0.22))
        ctx.restoreGState()
        ctx.setFillColor(color(p.accent, alpha: 0.85))
        for (x, y) in [(0.12, 0.86), (0.24, 0.74), (0.38, 0.90), (0.50, 0.70), (0.20, 0.60), (0.90, 0.56)] {
            ctx.fillEllipse(in: CGRect(x: s * x, y: s * y, width: s * 0.012, height: s * 0.012))
        }
        ctx.setFillColor(color(p.ground))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.34))
        let road = CGMutablePath()
        road.move(to: CGPoint(x: s * 0.30, y: 0))
        road.addQuadCurve(to: CGPoint(x: s * 0.62, y: s * 0.34), control: CGPoint(x: s * 0.80, y: s * 0.12))
        ctx.addPath(road)
        ctx.setStrokeColor(color(0x1C2333))
        ctx.setLineWidth(s * 0.10)
        ctx.strokePath()
        ctx.addPath(road)
        ctx.setStrokeColor(color(p.detail))
        ctx.setLineWidth(s * 0.012)
        ctx.setLineDash(phase: 0, lengths: [s * 0.04, s * 0.03])
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }
}
