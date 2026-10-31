// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) HudViewActivity.kt:297-355 (input-controls.md §3.4): phone
// touches on the dash picture become dash touches in CANVAS pixels and enter the same input path
// as real dash touches (DOWN / MOVE / UP, pointer 0, monotonic time). The picture is laid out with
// the canvas aspect ratio, so the inverse aspect-fit reduces to a linear scale; points outside the
// picture start nothing and later points are clamped so an UP is always delivered.

import SwiftUI
import OpenCfMotoCore

/// A canvas pixel.
struct DashPreviewPoint: Equatable {
    var x: Int
    var y: Int
}

struct DashPreviewSurface: View {
    let frame: DashPreviewFrame?
    /// Canvas to lay out with before the first picture arrives.
    let fallbackCanvas: DashSize
    var onTouch: (DashTouch.Action, DashPreviewPoint) -> Void
    var onSizeChange: (CGSize) -> Void = { _ in }

    @State private var touchDown = false
    @State private var lastPoint: DashPreviewPoint?
    @GestureState private var gestureActive = false

    var body: some View {
        let canvas = frame?.canvas ?? fallbackCanvas
        let aspect = canvas.height > 0 ? canvas.width / canvas.height : 800.0 / 384.0
        GeometryReader { geo in
            ZStack {
                Color.black
                if let frame {
                    Image(frame.image, scale: 1, label: Text("Dash picture"))
                        .resizable()
                        .interpolation(.medium)
                } else {
                    ProgressView()
                        .tint(Theme.brand)
                }
            }
            .contentShape(Rectangle())
            .gesture(touchGesture(viewSize: geo.size, canvas: canvas))
            .onAppear { onSizeChange(geo.size) }
            .onChange(of: geo.size) { _, size in onSizeChange(size) }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.outline, lineWidth: 1))
        .onChange(of: gestureActive) { _, active in
            // Gesture cancelled by the system (no onEnded): still lift the finger on the dash.
            if !active, touchDown { finish(at: lastPoint) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Dash picture"))
        .accessibilityHint(Text("Shows the dash. Tap or drag it like the dash touchscreen; the keypad works with VoiceOver."))
        .accessibilityAddTraits(.isImage)
    }

    private func touchGesture(viewSize: CGSize, canvas: DashSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($gestureActive) { _, state, _ in state = true }
            .onChanged { value in
                if !touchDown {
                    guard let start = Self.canvasPoint(value.startLocation, viewSize: viewSize, canvas: canvas,
                                                       clampOutside: false) else { return }
                    touchDown = true
                    lastPoint = start
                    onTouch(.down, start)
                }
                guard let point = Self.canvasPoint(value.location, viewSize: viewSize, canvas: canvas,
                                                   clampOutside: true), point != lastPoint else { return }
                lastPoint = point
                onTouch(.move, point)
            }
            .onEnded { value in
                guard touchDown else { return }
                let point = Self.canvasPoint(value.location, viewSize: viewSize, canvas: canvas, clampOutside: true)
                finish(at: point ?? lastPoint)
            }
    }

    private func finish(at point: DashPreviewPoint?) {
        touchDown = false
        if let point { onTouch(.up, point) }
        lastPoint = nil
    }

    /// View point → canvas pixel. `nil` when outside the picture (unless clamped) or degenerate.
    static func canvasPoint(_ location: CGPoint, viewSize: CGSize, canvas: DashSize,
                            clampOutside: Bool) -> DashPreviewPoint? {
        guard viewSize.width > 0, viewSize.height > 0, canvas.width >= 1, canvas.height >= 1,
              location.x.isFinite, location.y.isFinite else { return nil }
        let inside = location.x >= 0 && location.y >= 0 && location.x < viewSize.width && location.y < viewSize.height
        if !inside && !clampOutside { return nil }
        let fx = min(max(Double(location.x) / Double(viewSize.width), 0), 1)
        let fy = min(max(Double(location.y) / Double(viewSize.height), 0), 1)
        let maxX = max(Int(canvas.width) - 1, 0)
        let maxY = max(Int(canvas.height) - 1, 0)
        let x = min(Int((fx * canvas.width).rounded(.down)), maxX)
        let y = min(Int((fy * canvas.height).rounded(.down)), maxY)
        return DashPreviewPoint(x: x, y: y)
    }
}
