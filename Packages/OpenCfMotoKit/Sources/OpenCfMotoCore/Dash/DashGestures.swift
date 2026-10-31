// SPDX-License-Identifier: AGPL-3.0-or-later
// Dash touch gestures — docs/spec/input-controls.md §5 (pointer-set semantics), §6.2 (recommended
// iOS recognizer: tap on controls, long-press 450 ms, double-tap 300 ms / 100·s, pan > 8·s,
// pinch), §6.4 (pan ⇒ free pan). Android delivered dash touches single-pointer only (no pinch);
// the iOS dash UI implements real two-finger pinch.
//
// Input: filtered `DashTouch` events in canvas px (after the ghost filter). Output: gesture
// events applied by `DashUIController`. Pure value type; time is injected.

import Foundation

/// What a touch-down landed on (front-most hit region first).
public enum DashTouchTarget: Sendable, Equatable {
    /// A control: tap fires at UP while inside its rect expanded by the slop.
    case control(id: String, rect: DashRect)
    /// A control inside a scroll container: a drag beyond the slop scrolls the container instead.
    case controlInScroll(id: String, rect: DashRect, container: String)
    /// Background of a scroll container (menu panel, search list, chip rows).
    case scrollArea(container: String)
    /// A non-interactive card: swallows the gesture (no map pan / long-press through cards).
    case blocker
    /// The map.
    case map
    /// Inside the screen margins (unsafe area): ignored.
    case ignored
}

public enum DashGestureEvent: Sendable, Equatable {
    case tap(id: String)
    /// Single tap on the map (no action on Android; reported for completeness).
    case mapTap(DashPoint)
    case longPress(DashPoint)
    case doubleTap(DashPoint)
    case panBegan
    case pan(delta: DashPoint)
    case panEnded
    /// Two-finger pinch: `scale` relative to the previous pinch event, focal = midpoint,
    /// `translation` = midpoint movement since the previous pinch event.
    case pinch(scale: Double, focal: DashPoint, translation: DashPoint)
    case scroll(container: String, delta: DashPoint)
}

/// Thresholds (input-controls.md §6.2) in canvas px / seconds.
public struct DashGestureConfig: Sendable, Equatable {
    public var touchSlop: Double
    public var longPress: TimeInterval
    public var doubleTapTimeout: TimeInterval
    public var doubleTapMinTime: TimeInterval
    public var doubleTapSlop: Double

    public init(touchSlop: Double = 8, longPress: TimeInterval = 0.45, doubleTapTimeout: TimeInterval = 0.30,
                doubleTapMinTime: TimeInterval = 0.04, doubleTapSlop: Double = 100) {
        self.touchSlop = touchSlop; self.longPress = longPress; self.doubleTapTimeout = doubleTapTimeout
        self.doubleTapMinTime = doubleTapMinTime; self.doubleTapSlop = doubleTapSlop
    }

    /// Slop 8·s, double-tap slop 100·s for density scale `s`.
    public static func scaled(_ s: Double) -> DashGestureConfig {
        DashGestureConfig(touchSlop: 8 * s, doubleTapSlop: 100 * s)
    }
}

public struct DashGestureRecognizer: Sendable {
    public var config: DashGestureConfig
    /// Tracked pointers in insertion order (§5 touch-set state machine).
    public private(set) var pointers: [(id: Int, point: DashPoint)] = []

    private struct Press: Sendable {
        var target: DashTouchTarget
        var start: DashPoint
        var startTime: TimeInterval
        var last: DashPoint
    }
    private enum State: Sendable {
        case idle
        case press(Press)
        case pan(last: DashPoint)
        case pinch(lastDistance: Double, lastMid: DashPoint)
        case scroll(container: String, last: DashPoint)
        case consumed
    }
    private var state: State = .idle
    /// Last single map tap: UP time and its DOWN point (double-tap detection).
    private var lastTap: (time: TimeInterval, point: DashPoint)?

    /// Tolerance for floating-point time differences.
    static let timeEpsilon: TimeInterval = 1e-6

    public init(config: DashGestureConfig = DashGestureConfig()) { self.config = config }

    /// True while a finger is down.
    public var isActive: Bool { !pointers.isEmpty }

    public mutating func reset() {
        pointers.removeAll()
        state = .idle
        lastTap = nil
    }

    private static func dist(_ a: DashPoint, _ b: DashPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
    private static func mid(_ a: DashPoint, _ b: DashPoint) -> DashPoint { DashPoint((a.x + b.x) / 2, (a.y + b.y) / 2) }

    /// Feeds one filtered touch (canvas px). `hitTest` resolves what a DOWN landed on.
    public mutating func process(_ t: DashTouch, point p: DashPoint, now: TimeInterval,
                                 hitTest: (DashPoint) -> DashTouchTarget) -> [DashGestureEvent] {
        let idx = pointers.firstIndex(where: { $0.id == t.pointerId })
        switch t.action {
        case .down:
            if let i = idx { pointers[i].point = p; return moved(now: now) }
            pointers.append((t.pointerId, p))
            return pointers.count == 1 ? begin(p, now: now, hitTest: hitTest) : secondPointerDown()
        case .move:
            if let i = idx {
                pointers[i].point = p
                return moved(now: now)
            }
            // Lost DOWN: promote (§5).
            pointers.append((t.pointerId, p))
            return pointers.count == 1 ? begin(p, now: now, hitTest: hitTest) : secondPointerDown()
        case .up:
            guard let i = idx else { return [] } // untracked UP ignored
            pointers.remove(at: i)
            return pointers.isEmpty ? end(p, now: now) : pointerLifted()
        }
    }

    /// Timer: fires the long-press when a map press is held ≥ 450 ms without moving.
    public mutating func tick(now: TimeInterval) -> [DashGestureEvent] {
        if case let .press(press) = state, press.target == .map, now - press.startTime >= config.longPress - Self.timeEpsilon {
            state = .consumed
            lastTap = nil
            return [.longPress(press.start)]
        }
        return []
    }

    private mutating func begin(_ p: DashPoint, now: TimeInterval, hitTest: (DashPoint) -> DashTouchTarget) -> [DashGestureEvent] {
        let target = hitTest(p)
        switch target {
        case .ignored:
            state = .consumed
            return []
        case .map:
            if let lt = lastTap {
                let dt = now - lt.time
                if dt <= config.doubleTapTimeout + Self.timeEpsilon, dt >= config.doubleTapMinTime - Self.timeEpsilon, Self.dist(p, lt.point) <= config.doubleTapSlop {
                    lastTap = nil
                    state = .consumed
                    return [.doubleTap(p)]
                }
            }
            state = .press(Press(target: .map, start: p, startTime: now, last: p))
            return []
        default:
            lastTap = nil
            state = .press(Press(target: target, start: p, startTime: now, last: p))
            return []
        }
    }

    private mutating func moved(now: TimeInterval) -> [DashGestureEvent] {
        guard let first = pointers.first else { return [] }
        switch state {
        case var .press(press):
            if pointers.count >= 2 { return [] }
            let p = first.point
            press.last = p
            if Self.dist(p, press.start) > config.touchSlop {
                let delta = DashPoint(p.x - press.start.x, p.y - press.start.y)
                switch press.target {
                case .map:
                    lastTap = nil
                    state = .pan(last: p)
                    return [.panBegan, .pan(delta: delta)]
                case let .scrollArea(container), let .controlInScroll(_, _, container):
                    state = .scroll(container: container, last: p)
                    return [.scroll(container: container, delta: delta)]
                case .control:
                    state = .press(press) // still a tap if released inside the slop-expanded rect
                    return []
                case .blocker, .ignored:
                    state = .consumed
                    return []
                }
            }
            state = .press(press)
            if press.target == .map, now - press.startTime >= config.longPress - Self.timeEpsilon {
                state = .consumed
                lastTap = nil
                return [.longPress(press.start)]
            }
            return []
        case let .pan(last):
            let p = first.point
            state = .pan(last: p)
            return [.pan(delta: DashPoint(p.x - last.x, p.y - last.y))]
        case let .scroll(container, last):
            let p = first.point
            state = .scroll(container: container, last: p)
            return [.scroll(container: container, delta: DashPoint(p.x - last.x, p.y - last.y))]
        case let .pinch(lastDistance, lastMid):
            guard pointers.count >= 2 else { return [] }
            let a = pointers[0].point, b = pointers[1].point
            let d = Self.dist(a, b), m = Self.mid(a, b)
            state = .pinch(lastDistance: d, lastMid: m)
            let scale = lastDistance > 0 && d > 0 ? d / lastDistance : 1
            return [.pinch(scale: scale, focal: m, translation: DashPoint(m.x - lastMid.x, m.y - lastMid.y))]
        case .idle, .consumed:
            return []
        }
    }

    private mutating func secondPointerDown() -> [DashGestureEvent] {
        guard pointers.count >= 2 else { return [] }
        let a = pointers[0].point, b = pointers[1].point
        switch state {
        case let .press(press) where press.target == .map:
            lastTap = nil
            state = .pinch(lastDistance: Self.dist(a, b), lastMid: Self.mid(a, b))
            return [.panBegan]
        case .pan:
            state = .pinch(lastDistance: Self.dist(a, b), lastMid: Self.mid(a, b))
            return []
        default:
            return []
        }
    }

    private mutating func pointerLifted() -> [DashGestureEvent] {
        if case .pinch = state, let remaining = pointers.first {
            state = .pan(last: remaining.point)
        }
        return []
    }

    private mutating func end(_ p: DashPoint, now: TimeInterval) -> [DashGestureEvent] {
        defer { state = .idle }
        switch state {
        case let .press(press):
            switch press.target {
            case .map:
                if now - press.startTime >= config.longPress - Self.timeEpsilon {
                    lastTap = nil
                    return [.longPress(press.start)]
                }
                lastTap = (now, press.start)
                return [.mapTap(p)]
            case let .control(id, rect), let .controlInScroll(id, rect, _):
                let s = config.touchSlop
                return rect.insetBy(dx: -s, dy: -s).contains(p) ? [.tap(id: id)] : []
            default:
                return []
            }
        case .pan, .pinch:
            return [.panEnded]
        default:
            return []
        }
    }
}
