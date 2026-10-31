// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) BikeProfile.kt (HuTimeSync) and PxcHandshake.kt (onHuQueryTime)
//
// Dash clock frames on the control plane (docs/spec/control-plane.md §13):
// - HU_TIME_SYNC 0x10600 (≈ every 2 s): reply 0x10601 with the request bytes ECHOED, zero-padded to
//   45 bytes. Phone local time is written only when the dash reports a blank / short / 1969–1971
//   stamp (2.0.10+ behaviour; rewriting with phone time made several brands jump hours).
// - HU_QUERY_TIME 0x10450: reply an EMPTY 0x10451 (default "Latest" clock mode).
// Never send an unsolicited 0x10601 and never advertise supportSyncCorrectTime:true.

import Foundation

public enum HuTimeSync {
    /// Live payload length (16-byte header + 29 ASCII chars).
    public static let payloadLength = 45
    public static let stampOffset = 16
    public static let stampLength = 29

    public enum Mode: String, Sendable, Equatable {
        /// The dash's own bytes were echoed.
        case echo
        /// Phone local time was written at offset 16.
        case phone
    }

    /// A 0x10601 body and how it was built.
    public struct Ack: Sendable, Equatable {
        public var payload: Data
        public var mode: Mode
        /// The stamp the dash will see (the echoed one, or the phone stamp).
        public var stamp: String
    }

    /// Builds the 0x10601 body for a 0x10600 request.
    /// - Parameters:
    ///   - forcePhone: Clock-lab "phone" knob (default off): always write phone time.
    ///   - nowMillis: wall clock in epoch milliseconds (injected for tests).
    ///   - timeZone: the device zone, re-read per call by the caller (`TimeZone.current`).
    public static func ack(request: Data, forcePhone: Bool = false,
                           nowMillis: Int64 = HuTimeSync.currentMillis(),
                           timeZone: TimeZone = .current) -> Ack {
        let req = [UInt8](request)
        let len = max(payloadLength, req.count)
        var out = [UInt8](repeating: 0, count: len)
        if !req.isEmpty { out.replaceSubrange(0 ..< req.count, with: req) }
        if req.count < stampOffset {
            // Missing / short header → synthesize (-2, 0, 1, 0).
            var w = ByteWriter(capacity: 16)
            w.i32le(-2)
            w.i32le(0)
            w.i32le(1)
            w.i32le(0)
            out.replaceSubrange(0 ..< 16, with: w.bytes)
        }
        let bikeStamp = extractStamp(request)
        if !forcePhone, shouldEcho(stamp: bikeStamp, request: request) {
            return Ack(payload: Data(out), mode: .echo, stamp: bikeStamp)
        }
        let stamp = phoneStamp(nowMillis: nowMillis, timeZone: timeZone)
        let ascii = Array(stamp.utf8.prefix(stampLength))
        out.replaceSubrange(stampOffset ..< stampOffset + ascii.count, with: ascii)
        return Ack(payload: Data(out), mode: .phone, stamp: stamp)
    }

    /// The dash stamp: bytes 16 ..< 16+min(29, n-16) as ASCII (non-ASCII → U+FFFD), trailing NULs
    /// and spaces trimmed; "" when the request is shorter than 16 bytes.
    public static func extractStamp(_ buffer: Data) -> String {
        let b = [UInt8](buffer)
        guard b.count >= stampOffset else { return "" }
        let n = min(stampLength, b.count - stampOffset)
        var scalars = b[stampOffset ..< stampOffset + n].map { $0 < 0x80 ? Character(Unicode.Scalar($0)) : "\u{FFFD}" }
        while let last = scalars.last, last == "\u{0}" || last == " " { scalars.removeLast() }
        return String(scalars)
    }

    /// Echo unless the request is short or the stamp is blank / epoch (year 1969…1971).
    public static func shouldEcho(stamp: String, request: Data) -> Bool {
        if request.count < stampOffset { return false }
        if isBlank(stamp) || stamp.allSatisfy({ $0 == "\u{0}" || $0 == " " }) { return false }
        if let year = leadingStampYear(stamp), (1969 ... 1971).contains(year) { return false }
        return true
    }

    /// Year 2020…2099 stamp (Android keeps it for tests only).
    public static func isSaneStamp(_ stamp: String) -> Bool {
        guard let year = leadingStampYear(stamp) else { return false }
        return (2020 ... 2099).contains(year)
    }

    /// `yyyy-MM-dd HH:mm:ss` + "." + 3-digit milliseconds + "000000", formatted with
    /// en_US_POSIX / Gregorian in `timeZone`, seconds and milliseconds from ONE epoch-ms value.
    public static func phoneStamp(nowMillis: Int64, timeZone: TimeZone) -> String {
        let seconds = nowMillis >= 0 ? nowMillis / 1000 : -((-nowMillis + 999) / 1000)
        let millis = Int(nowMillis - seconds * 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let base = f.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        let ms = String(millis)
        return base + "." + String(repeating: "0", count: max(0, 3 - ms.count)) + ms + "000000"
    }

    /// Current wall clock in epoch milliseconds.
    public static func currentMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// The 0x10601 frame for a request.
    public static func replyFrame(to request: PxcFrame, forcePhone: Bool = false,
                                  nowMillis: Int64 = HuTimeSync.currentMillis(),
                                  timeZone: TimeZone = .current) -> (frame: PxcFrame, ack: Ack) {
        let a = ack(request: request.payload, forcePhone: forcePhone, nowMillis: nowMillis, timeZone: timeZone)
        return (PxcFrame(cmd: PxcCmd.huTimeSyncAck, payload: a.payload), a)
    }

    // MARK: helpers

    /// Kotlin `isBlank()` (every char is whitespace; NUL is NOT whitespace).
    private static func isBlank(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }

    /// Matches `^(\d{4})-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}` (ASCII digits) and returns the year.
    static func leadingStampYear(_ stamp: String) -> Int? {
        let u = Array(stamp.utf16) // Java char indices
        guard u.count >= 19 else { return nil }
        func digit(_ i: Int) -> Bool { u[i] >= 0x30 && u[i] <= 0x39 }
        let pattern: [(Int, (UInt16) -> Bool)] = [
            (4, { $0 == 0x2D }), (7, { $0 == 0x2D }), (10, { $0 == 0x20 || $0 == 0x54 }),
            (13, { $0 == 0x3A }), (16, { $0 == 0x3A }),
        ]
        for i in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18] where !digit(i) { return nil }
        for (i, ok) in pattern where !ok(u[i]) { return nil }
        return Int(String(decoding: u[0 ..< 4], as: UTF16.self))
    }
}

/// HU_QUERY_TIME (0x10450) reply. Default clock mode "empty" (Android 2.0.13+): an empty 0x10451.
public enum HuQueryTime {
    public static func replyFrame() -> PxcFrame { PxcFrame(cmd: PxcCmd.huQueryTimeAck) }
}
