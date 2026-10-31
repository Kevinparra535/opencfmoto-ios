// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) DashMemory.kt
//
// Learned dash geometry (session-network.md §8.2, media-video.md §10.2): the UNROUNDED canvas size the
// dash asked for in REQ_RV_CONFIG_CAPTURE, stored per SSID as `"<w>x<h>"` under `dash_geo_<ssid>`.
// Used to pre-size the renderer/encoder before the dash connects. It never alters RLY 17.

import Foundation

/// A learned dash size (unrounded REQ 16 width × height).
public struct LearnedDashSize: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    /// `"<w>x<h>"` — the persisted form.
    public var description: String { "\(width)x\(height)" }
    /// The canvas the dash will negotiate for this size (`& 0xFFF0`).
    public var canvas: VideoCanvas { VideoCanvas.rounded(requestedWidth: width, requestedHeight: height) }
}

/// Per-SSID learned canvas memory over a `KeyValueStore` (thread-safe: the store is).
public final class DashMemory: @unchecked Sendable {
    /// Key prefix: `dash_geo_<ssid>` (exact, case-sensitive SSID).
    public static let keyPrefix = "dash_geo_"
    /// Whether the active profile advertised a touchscreen at the last connect (UI hint).
    public static let lastDashTouchKey = "last_dash_touch"

    private let store: KeyValueStore

    public init(store: KeyValueStore) {
        self.store = store
    }

    /// Records the size a dash requested (REQ 16). Ignored when the SSID is nil/blank or a dimension
    /// is ≤ 0. Returns true (and logs `[panel] learned: …`) when the stored value changed.
    @discardableResult
    public func observe(ssid: String?, width: Int, height: Int) -> Bool {
        guard let ssid, !AppJvmText.isBlank(ssid), width > 0, height > 0 else { return false }
        let key = Self.keyPrefix + ssid
        let now = "\(width)x\(height)"
        let prior = store.string(forKey: key)
        store.set(now, forKey: key)
        if prior != now {
            Log.i("panel", "learned: this bike's screen is \(now) \u{2014} next connect will fit AA resolution + match-aspect margins to it")
            return true
        }
        return false
    }

    /// Records a negotiated canvas using its unrounded requested size.
    @discardableResult
    public func observe(ssid: String?, canvas: VideoCanvas) -> Bool {
        observe(ssid: ssid, width: canvas.requestedWidth, height: canvas.requestedHeight)
    }

    /// The learned size for `ssid`, if stored and both dimensions lie in 1…8192.
    public func learnedSize(forSSID ssid: String?) -> LearnedDashSize? {
        guard let ssid, !AppJvmText.isBlank(ssid),
              let value = store.string(forKey: Self.keyPrefix + ssid) else { return nil }
        return Self.parse(value)
    }

    /// The canvas the dash will most likely negotiate (learned size rounded `& 0xFFF0`).
    public func learnedCanvas(forSSID ssid: String?) -> VideoCanvas? {
        learnedSize(forSSID: ssid)?.canvas
    }

    /// Forgets the learned size of one SSID.
    public func forget(ssid: String) {
        store.removeValue(forKey: Self.keyPrefix + ssid)
    }

    /// Last advertised touch state (nil when never recorded).
    public func lastDashTouch() -> Bool? { store.bool(forKey: Self.lastDashTouchKey) }

    public func setLastDashTouch(_ touch: Bool) { store.set(touch, forKey: Self.lastDashTouchKey) }

    /// Parses `"<w>x<h>"` like Android (`split("x")`, Kotlin `toIntOrNull`, extra parts ignored),
    /// accepting only 1…8192 per axis.
    public static func parse(_ value: String) -> LearnedDashSize? {
        let parts = AppJvmText.split(value, "x")
        guard parts.count >= 2,
              let w = AppJvmText.toIntOrNull(parts[0]),
              let h = AppJvmText.toIntOrNull(parts[1]),
              (1 ... 8192).contains(w), (1 ... 8192).contains(h) else { return nil }
        return LearnedDashSize(width: w, height: h)
    }

    // MARK: - Android Auto best fit (reference; AA-only on Android)

    /// Android Auto coded sizes (`AaResolution`), in Android enum order (the tie-break order).
    public enum AAResolution: String, Sendable, CaseIterable, Codable {
        case landscape800x480, landscape1280x720, portrait720x1280, portrait1080x1920
        public var width: Int {
            switch self {
            case .landscape800x480: return 800
            case .landscape1280x720: return 1280
            case .portrait720x1280: return 720
            case .portrait1080x1920: return 1080
            }
        }
        public var height: Int {
            switch self {
            case .landscape800x480: return 480
            case .landscape1280x720: return 720
            case .portrait720x1280: return 1280
            case .portrait1080x1920: return 1920
            }
        }
    }

    /// `DashMemory.bestFit`: round both axes `& 0xFFF0`, keep AA sizes matching one axis exactly and
    /// covering the other, pick the minimum of `(rw−cw)(rh−ch) + (rw−cw) + (rh−ch)` (first wins on ties).
    public static func bestFit(width: Int, height: Int) -> AAResolution? {
        let cw = width & 0xFFF0
        let ch = height & 0xFFF0
        var best: AAResolution?
        var bestScore = Int64.max
        for r in AAResolution.allCases where (r.width == cw && r.height >= ch) || (r.height == ch && r.width >= cw) {
            let score = Int64(r.width - cw) * Int64(r.height - ch) + Int64(r.width - cw) + Int64(r.height - ch)
            if score < bestScore {
                bestScore = score
                best = r
            }
        }
        return best
    }
}
