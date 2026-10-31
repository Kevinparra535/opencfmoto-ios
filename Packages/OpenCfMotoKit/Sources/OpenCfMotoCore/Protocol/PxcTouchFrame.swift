// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnProber.kt (handleTouch, wire decode part)
//
// Dash touch: media cmdType 32 on :10921 (accepted on either media socket), never answered
// (docs/spec/input-controls.md §2). Body, little-endian:
//   u16 action @0 (2 = DOWN, 3 = MOVE, 1 = UP) | u16 x @2 | u16 y @4 | u16 pointerId @6 |
//   u32 timestamp @8 (unit unknown, unused) | 6 unknown bytes. Coordinates are canvas pixels,
//   top-left origin.

import Foundation

/// One decoded touch frame (before ghost filtering).
public struct PxcTouchFrame: Sendable, Equatable, CustomStringConvertible {
    /// Raw wire action (2 = DOWN, 3 = MOVE, 1 = UP; anything else is dropped by the filter).
    public var rawAction: UInt16
    public var x: Int
    public var y: Int
    public var pointerId: Int
    /// Dash timestamp (u32 @8) when the body has ≥ 12 bytes. Unit/epoch unknown; logged only.
    public var timestamp: UInt32?

    public init(rawAction: UInt16, x: Int, y: Int, pointerId: Int = 0, timestamp: UInt32? = nil) {
        self.rawAction = rawAction
        self.x = x
        self.y = y
        self.pointerId = pointerId
        self.timestamp = timestamp
    }

    /// Minimum accepted body length (Android drops shorter bodies: "touch frame too short").
    public static let minimumBodyLength = 8

    /// Decodes a cmdType 32 body; nil if shorter than 8 bytes.
    public static func decode(_ body: Data) -> PxcTouchFrame? {
        let b = [UInt8](body)
        guard b.count >= minimumBodyLength else { return nil }
        func u16(_ i: Int) -> Int { Int(b[i]) | (Int(b[i + 1]) << 8) }
        var ts: UInt32?
        if b.count >= 12 {
            ts = UInt32(b[8]) | (UInt32(b[9]) << 8) | (UInt32(b[10]) << 16) | (UInt32(b[11]) << 24)
        }
        return PxcTouchFrame(rawAction: UInt16(u16(0)), x: u16(2), y: u16(4), pointerId: u16(6), timestamp: ts)
    }

    /// Normalized action (2 → down, 1 → up, 3 → move); nil for unknown raw actions.
    public var action: DashTouch.Action? { PxcTouchFrame.normalize(rawAction) }

    public static func normalize(_ raw: UInt16) -> DashTouch.Action? {
        switch raw {
        case 2: return .down
        case 1: return .up
        case 3: return .move
        default: return nil
        }
    }

    /// Raw wire action for a normalized action (for synthetic frames / tests).
    public static func rawAction(for action: DashTouch.Action) -> UInt16 {
        switch action {
        case .down: return 2
        case .up: return 1
        case .move: return 3
        }
    }

    /// Encodes an 18-byte body (6 trailing unknown bytes zero) — test dashes / simulators.
    public func encodedBody() -> Data {
        var w = ByteWriter(capacity: 18)
        w.u16le(rawAction)
        w.u16le(UInt16(truncatingIfNeeded: x))
        w.u16le(UInt16(truncatingIfNeeded: y))
        w.u16le(UInt16(truncatingIfNeeded: pointerId))
        w.u32le(timestamp ?? 0)
        w.zeros(6)
        return w.data
    }

    public var description: String {
        let name: String
        switch action {
        case .down?: name = "DOWN"
        case .up?: name = "UP"
        case .move?: name = "MOVE"
        case nil: name = "action=\(rawAction)"
        }
        return "touch \(name) (\(x),\(y)) ptr=\(pointerId)"
    }
}
