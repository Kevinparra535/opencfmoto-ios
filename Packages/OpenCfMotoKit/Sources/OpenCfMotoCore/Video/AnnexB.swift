// SPDX-License-Identifier: AGPL-3.0-or-later
// H.264 bitstream helpers. VideoToolbox emits AVCC (length-prefixed NAL units) and keeps SPS/PPS
// in the CMFormatDescription; the dash wants Annex-B access units with 4-byte start codes and
// SPS + PPS in front of EVERY IDR (docs/spec/media-video.md "frame wire format").

import Foundation

public enum H264NALType: UInt8 {
    case nonIDRSlice = 1
    case idrSlice = 5
    case sei = 6
    case sps = 7
    case pps = 8
    case accessUnitDelimiter = 9
    case endOfSequence = 10
    case endOfStream = 11
    case filler = 12
}

public enum AnnexB {
    public static let startCode: [UInt8] = [0, 0, 0, 1]

    /// NAL types removed when converting VT output: SEI, AUD and filler (not needed by the dash,
    /// and the known-good Android stream did not depend on them).
    public static let defaultDroppedTypes: Set<UInt8> = [6, 9, 12]

    /// nal_unit_type of a NAL unit (first byte & 0x1F), nil for empty input.
    public static func nalType(_ nal: Data) -> UInt8? {
        guard let first = nal.first else { return nil }
        return first & 0x1F
    }

    /// Splits AVCC data (big-endian length prefixes of `lengthSize` bytes) into NAL units.
    /// Stops at the first malformed length.
    public static func nalUnits(avcc data: Data, lengthSize: Int = 4) -> [Data] {
        let bytes = [UInt8](data)
        var out: [Data] = []
        var i = 0
        while i + lengthSize <= bytes.count {
            var len = 0
            for k in 0 ..< lengthSize { len = (len << 8) | Int(bytes[i + k]) }
            i += lengthSize
            guard len > 0, i + len <= bytes.count else { break }
            out.append(Data(bytes[i ..< i + len]))
            i += len
        }
        return out
    }

    /// Splits Annex-B data on 3- or 4-byte start codes into NAL units (without start codes).
    public static func nalUnits(annexB data: Data) -> [Data] {
        let b = [UInt8](data)
        var starts: [(codeStart: Int, payloadStart: Int)] = []
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0 {
                if b[i + 2] == 1 {
                    starts.append((i, i + 3)); i += 3; continue
                } else if i + 4 <= b.count, b[i + 2] == 0, b[i + 3] == 1 {
                    starts.append((i, i + 4)); i += 4; continue
                }
            }
            i += 1
        }
        var out: [Data] = []
        for (n, s) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].codeStart : b.count
            if end > s.payloadStart { out.append(Data(b[s.payloadStart ..< end])) }
        }
        return out
    }

    /// Joins NAL units into Annex-B with 4-byte start codes.
    public static func join(_ nals: [Data]) -> Data {
        var out = Data()
        out.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for n in nals where !n.isEmpty {
            out.append(contentsOf: startCode)
            out.append(n)
        }
        return out
    }

    /// Builds the wire access unit from VT output: AVCC slices → Annex-B, dropping `dropping` types,
    /// and — when the slices contain an IDR — prefixing SPS and PPS (each once, 4-byte start codes).
    /// Any SPS/PPS already inside the slices are removed first so they never appear twice.
    public static func accessUnit(avccSlices: Data, lengthSize: Int = 4, sps: [Data], pps: [Data],
                                  dropping: Set<UInt8> = defaultDroppedTypes) -> (data: Data, isKeyframe: Bool) {
        let nals = nalUnits(avcc: avccSlices, lengthSize: lengthSize)
        let slices = nals.filter { n in
            guard let t = nalType(n) else { return false }
            return !dropping.contains(t) && t != H264NALType.sps.rawValue && t != H264NALType.pps.rawValue
        }
        let isKey = slices.contains { nalType($0) == H264NALType.idrSlice.rawValue }
        let all = isKey ? (sps + pps + slices) : slices
        return (join(all), isKey)
    }

    /// True if the Annex-B access unit contains an IDR slice.
    public static func containsIDR(annexB data: Data) -> Bool {
        nalUnits(annexB: data).contains { nalType($0) == H264NALType.idrSlice.rawValue }
    }
}
