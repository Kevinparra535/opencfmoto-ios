// SPDX-License-Identifier: AGPL-3.0-or-later
// Minimal H.264 sequence parameter set reader (ITU-T H.264 §7.3.2.1.1): profile, level and the
// coded picture size after frame cropping. Used to tell which canvas an IDR was encoded for — the
// mirror host must never serve an access unit whose size differs from the latest RLY 17 (rule 4/8,
// media-video.md §9.2): e.g. a broadcast-extension IDR encoded at the 800×384 default before the
// host's CONFIG arrived, or one from a previous session's canvas (MP-3).
//
// Pure Swift, defensive: any truncated / malformed input yields nil (never traps).

import Foundation

public struct H264SPSInfo: Sendable, Equatable {
    public var profileIdc: Int
    public var levelIdc: Int
    /// Displayed size (coded size minus frame cropping), in pixels.
    public var width: Int
    public var height: Int

    public init(profileIdc: Int, levelIdc: Int, width: Int, height: Int) {
        self.profileIdc = profileIdc
        self.levelIdc = levelIdc
        self.width = width
        self.height = height
    }
}

public enum H264SPS {
    /// Parses one SPS NAL unit (with its 1-byte NAL header, without a start code).
    public static func parse(nal: Data) -> H264SPSInfo? {
        let bytes = [UInt8](nal)
        guard bytes.count >= 4, bytes[0] & 0x1F == H264NALType.sps.rawValue else { return nil }
        var r = H264BitReader(rbsp: removeEmulationPrevention(Array(bytes.dropFirst())))
        guard let profile = r.bits(8), r.bits(8) != nil, let level = r.bits(8), r.ue() != nil else { return nil }
        var chromaFormat = 1
        var separateColourPlane = false
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            guard let cf = r.ue(), cf <= 3 else { return nil }
            chromaFormat = cf
            if cf == 3 {
                guard let flag = r.bit() else { return nil }
                separateColourPlane = flag == 1
            }
            guard r.ue() != nil, r.ue() != nil, r.bit() != nil, let scaling = r.bit() else { return nil } // bit depths, bypass
            if scaling == 1 {
                for i in 0 ..< (chromaFormat != 3 ? 8 : 12) {
                    guard let present = r.bit() else { return nil }
                    if present == 1, !r.skipScalingList(size: i < 6 ? 16 : 64) { return nil }
                }
            }
        }
        guard r.ue() != nil, let pocType = r.ue() else { return nil } // log2_max_frame_num_minus4
        if pocType == 0 {
            guard r.ue() != nil else { return nil }
        } else if pocType == 1 {
            guard r.bit() != nil, r.se() != nil, r.se() != nil, let cycle = r.ue(), cycle <= 255 else { return nil }
            for _ in 0 ..< cycle { guard r.se() != nil else { return nil } }
        } else if pocType != 2 {
            return nil
        }
        guard r.ue() != nil, r.bit() != nil, // max_num_ref_frames, gaps_in_frame_num_allowed
              let widthMbsMinus1 = r.ue(), let heightMapUnitsMinus1 = r.ue(), let frameMbsOnly = r.bit() else { return nil }
        if frameMbsOnly == 0 { guard r.bit() != nil else { return nil } } // mb_adaptive_frame_field
        guard r.bit() != nil, let cropping = r.bit() else { return nil } // direct_8x8_inference
        var crop = (left: 0, right: 0, top: 0, bottom: 0)
        if cropping == 1 {
            guard let l = r.ue(), let rt = r.ue(), let t = r.ue(), let b = r.ue() else { return nil }
            crop = (l, rt, t, b)
        }
        guard widthMbsMinus1 < 1024, heightMapUnitsMinus1 < 1024 else { return nil } // ≤ 16384 px
        let frameHeightFactor = 2 - frameMbsOnly
        let codedW = (widthMbsMinus1 + 1) * 16
        let codedH = frameHeightFactor * (heightMapUnitsMinus1 + 1) * 16
        // Crop units (Table 6-1): ChromaArrayType 0 (monochrome or separate planes) → 1 × (2 − fmo).
        let chromaArrayType = separateColourPlane ? 0 : chromaFormat
        let (subW, subH): (Int, Int) = chromaArrayType == 1 ? (2, 2) : chromaArrayType == 2 ? (2, 1) : (1, 1)
        let cropUnitX = chromaArrayType == 0 ? 1 : subW
        let cropUnitY = (chromaArrayType == 0 ? 1 : subH) * frameHeightFactor
        guard crop.left < 4096, crop.right < 4096, crop.top < 4096, crop.bottom < 4096 else { return nil }
        let w = codedW - cropUnitX * (crop.left + crop.right)
        let h = codedH - cropUnitY * (crop.top + crop.bottom)
        guard w > 0, h > 0 else { return nil }
        return H264SPSInfo(profileIdc: profile, levelIdc: level, width: w, height: h)
    }

    /// The SPS of an Annex-B access unit (the first SPS NAL), parsed; nil if absent or malformed.
    public static func parse(accessUnit: Data) -> H264SPSInfo? {
        guard let sps = AnnexB.nalUnits(annexB: accessUnit).first(where: { AnnexB.nalType($0) == H264NALType.sps.rawValue })
        else { return nil }
        return parse(nal: sps)
    }

    /// The RBSP of a NAL payload: every 0x03 that follows two zero bytes is an emulation-prevention
    /// byte and is removed.
    static func removeEmulationPrevention(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var zeros = 0
        for byte in b {
            if zeros >= 2, byte == 0x03 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}

/// MSB-first bit reader with Exp-Golomb codes (H.264 §9.1). Every read returns nil past the end.
struct H264BitReader {
    private let data: [UInt8]
    private var position = 0 // in bits

    init(rbsp: [UInt8]) { data = rbsp }

    mutating func bit() -> Int? {
        guard position < data.count * 8 else { return nil }
        let v = (data[position >> 3] >> (7 - UInt8(position & 7))) & 1
        position += 1
        return Int(v)
    }

    mutating func bits(_ n: Int) -> Int? {
        guard n >= 0, n <= 32 else { return nil }
        var v = 0
        for _ in 0 ..< n {
            guard let b = bit() else { return nil }
            v = (v << 1) | b
        }
        return v
    }

    /// ue(v); nil past the end or for codes longer than 31 bits.
    mutating func ue() -> Int? {
        var zeros = 0
        while true {
            guard let b = bit() else { return nil }
            if b == 1 { break }
            zeros += 1
            if zeros > 31 { return nil }
        }
        guard let suffix = bits(zeros) else { return nil }
        return (1 << zeros) - 1 + suffix
    }

    /// se(v).
    mutating func se() -> Int? {
        guard let k = ue() else { return nil }
        return k % 2 == 1 ? (k + 1) / 2 : -(k / 2)
    }

    /// scaling_list(): reads (and discards) the delta_scale values; false past the end.
    mutating func skipScalingList(size: Int) -> Bool {
        var last = 8, next = 8
        for _ in 0 ..< size {
            if next != 0 {
                guard let delta = se() else { return false }
                next = (last + delta + 256) % 256
            }
            last = next == 0 ? last : next
        }
        return true
    }
}
