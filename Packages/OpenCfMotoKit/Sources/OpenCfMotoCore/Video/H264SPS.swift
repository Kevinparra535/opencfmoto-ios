// SPDX-License-Identifier: AGPL-3.0-or-later
// Minimal H.264 sequence parameter set reader (ITU-T H.264 §7.3.2.1.1): profile, level and the
// coded picture size after frame cropping. Used to tell which canvas an IDR was encoded for — the
// mirror host must never serve an access unit whose size differs from the latest RLY 17 (rule 4/8,
// media-video.md §9.2): e.g. a broadcast-extension IDR encoded at the 800×384 default before the
// host's CONFIG arrived, or one from a previous session's canvas (MP-3).
//
// ADDITION (locked iPhone, Phase 0, P0-1): the fields a dash decoder cares about (constraint flags,
// frame_num bits, POC type, reference frames, the VUI as far as bitstream_restriction) for the full
// `[label] first IDR … SPS … PPS …` log line and `H264StreamCheck`, and a PPS reader (§7.3.2.2).
//
// Pure Swift, defensive: any truncated / malformed input yields nil (never traps).

import Foundation

public struct H264SPSInfo: Sendable, Equatable {
    public var profileIdc: Int
    public var levelIdc: Int
    /// Displayed size (coded size minus frame cropping), in pixels.
    public var width: Int
    public var height: Int
    /// seq_parameter_set_id.
    public var seqParameterSetId: Int
    /// The constraint byte (constraint_set0_flag is the most significant bit), e.g. 0xE0, 0xC0, 0x00.
    public var constraintFlags: Int
    /// log2_max_frame_num_minus4 + 4: the bit length of frame_num in the slice headers.
    public var log2MaxFrameNum: Int
    /// pic_order_cnt_type (0, 1 or 2).
    public var pocType: Int
    /// max_num_ref_frames.
    public var maxNumRefFrames: Int
    /// frame_mbs_only_flag (false: field / MBAFF coding is possible).
    public var frameMbsOnly: Bool
    /// frame_cropping_flag (`width` / `height` above are already cropped).
    public var frameCropping: Bool
    /// vui_parameters_present_flag.
    public var vuiPresent: Bool
    /// VUI bitstream_restriction max_num_reorder_frames; nil when there is no VUI, no
    /// bitstream_restriction, or the VUI ends early (a truncated VUI never fails the SPS parse).
    public var maxNumReorderFrames: Int?
    /// VUI bitstream_restriction max_dec_frame_buffering; nil like `maxNumReorderFrames`.
    public var maxDecFrameBuffering: Int?

    public init(profileIdc: Int, levelIdc: Int, width: Int, height: Int, seqParameterSetId: Int = 0,
                constraintFlags: Int = 0, log2MaxFrameNum: Int = 4, pocType: Int = 0, maxNumRefFrames: Int = 0,
                frameMbsOnly: Bool = true, frameCropping: Bool = false, vuiPresent: Bool = false,
                maxNumReorderFrames: Int? = nil, maxDecFrameBuffering: Int? = nil) {
        self.profileIdc = profileIdc
        self.levelIdc = levelIdc
        self.width = width
        self.height = height
        self.seqParameterSetId = seqParameterSetId
        self.constraintFlags = constraintFlags
        self.log2MaxFrameNum = log2MaxFrameNum
        self.pocType = pocType
        self.maxNumRefFrames = maxNumRefFrames
        self.frameMbsOnly = frameMbsOnly
        self.frameCropping = frameCropping
        self.vuiPresent = vuiPresent
        self.maxNumReorderFrames = maxNumReorderFrames
        self.maxDecFrameBuffering = maxDecFrameBuffering
    }

    /// The SPS part of the L1 log line, exactly
    /// `profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=-`
    /// (`constraints`: two upper-case hex digits; `vui=yes|no`; `reorder=<n>`, or `-` when unknown).
    public var summary: String {
        let hex = String(constraintFlags & 0xFF, radix: 16, uppercase: true)
        return "profile \(profileIdc) constraints 0x\(hex.count < 2 ? "0" + hex : hex) level \(levelIdc) "
            + "\(width)x\(height) poc \(pocType) refs \(maxNumRefFrames) frame_num_bits \(log2MaxFrameNum) "
            + "vui=\(vuiPresent ? "yes" : "no") reorder=\(maxNumReorderFrames.map { String($0) } ?? "-")"
    }
}

/// ADDITION (locked iPhone, Phase 0, P0-1): a picture parameter set (H.264 §7.3.2.2), read as far as
/// `redundant_pic_cnt_present_flag`.
public struct H264PPSInfo: Sendable, Equatable {
    /// pic_parameter_set_id.
    public var picParameterSetId: Int
    /// The seq_parameter_set_id this PPS refers to.
    public var seqParameterSetId: Int
    /// entropy_coding_mode_flag: true = CABAC (never allowed on the dash), false = CAVLC.
    public var entropyCodingCABAC: Bool
    /// bottom_field_pic_order_in_frame_present_flag.
    public var bottomFieldPicOrderInFramePresent: Bool
    /// num_slice_groups_minus1 + 1.
    public var numSliceGroups: Int
    /// num_ref_idx_l0_default_active_minus1 + 1.
    public var numRefIdxL0DefaultActive: Int
    /// weighted_pred_flag.
    public var weightedPred: Bool
    /// weighted_bipred_idc.
    public var weightedBipredIdc: Int
    /// 26 + pic_init_qp_minus26.
    public var picInitQp: Int
    /// deblocking_filter_control_present_flag.
    public var deblockingFilterControlPresent: Bool
    /// constrained_intra_pred_flag.
    public var constrainedIntraPred: Bool
    /// redundant_pic_cnt_present_flag.
    public var redundantPicCntPresent: Bool

    public init(picParameterSetId: Int = 0, seqParameterSetId: Int = 0, entropyCodingCABAC: Bool = false,
                bottomFieldPicOrderInFramePresent: Bool = false, numSliceGroups: Int = 1,
                numRefIdxL0DefaultActive: Int = 1, weightedPred: Bool = false, weightedBipredIdc: Int = 0,
                picInitQp: Int = 26, deblockingFilterControlPresent: Bool = false, constrainedIntraPred: Bool = false,
                redundantPicCntPresent: Bool = false) {
        self.picParameterSetId = picParameterSetId
        self.seqParameterSetId = seqParameterSetId
        self.entropyCodingCABAC = entropyCodingCABAC
        self.bottomFieldPicOrderInFramePresent = bottomFieldPicOrderInFramePresent
        self.numSliceGroups = numSliceGroups
        self.numRefIdxL0DefaultActive = numRefIdxL0DefaultActive
        self.weightedPred = weightedPred
        self.weightedBipredIdc = weightedBipredIdc
        self.picInitQp = picInitQp
        self.deblockingFilterControlPresent = deblockingFilterControlPresent
        self.constrainedIntraPred = constrainedIntraPred
        self.redundantPicCntPresent = redundantPicCntPresent
    }

    /// The PPS part of the L1 log line, exactly `pps cavlc deblock_ctrl=1 qp=28` (`cavlc|cabac`,
    /// `deblock_ctrl=0|1`, `qp=<picInitQp>`).
    public var summary: String {
        "pps \(entropyCodingCABAC ? "cabac" : "cavlc") deblock_ctrl=\(deblockingFilterControlPresent ? 1 : 0) qp=\(picInitQp)"
    }
}

/// ADDITION (locked iPhone, Phase 0, P0-1): the PPS reader.
public enum H264PPS {
    /// Parses one PPS NAL unit (with its 1-byte NAL header, without a start code); nil when it is not
    /// a PPS (nal_unit_type 8) or is truncated / malformed. Slice groups (FMO) only need to be read
    /// far enough to report `numSliceGroups` (more than one is an `H264StreamCheck` issue anyway).
    public static func parse(nal: Data) -> H264PPSInfo? {
        _ = nal
        return nil // step-0 placeholder: K implements
    }

    /// The PPS of an Annex-B access unit (the first PPS NAL), parsed; nil if absent or malformed.
    public static func parse(accessUnit: Data) -> H264PPSInfo? {
        guard let pps = AnnexB.nalUnits(annexB: accessUnit).first(where: { AnnexB.nalType($0) == H264NALType.pps.rawValue })
        else { return nil }
        return parse(nal: pps)
    }
}

public enum H264SPS {
    /// Parses one SPS NAL unit (with its 1-byte NAL header, without a start code).
    /// Every field of `H264SPSInfo` is filled; the VUI is read as far as bitstream_restriction, and
    /// running out of bits inside the VUI keeps the SPS (`vuiPresent` true, reorder / buffering nil).
    /// step-0 placeholder: K implements the fields after `height` and the VUI (today they keep their
    /// `H264SPSInfo.init` defaults).
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
