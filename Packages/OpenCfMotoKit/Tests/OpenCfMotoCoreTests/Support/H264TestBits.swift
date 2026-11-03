// SPDX-License-Identifier: AGPL-3.0-or-later
// Test only: builds H.264 parameter sets and slice headers bit by bit (Exp-Golomb codes, rbsp trailing
// bits, emulation prevention) for the SPS / PPS parser and stream-check tests, plus the known-good byte
// vectors of the locked-iPhone contract (section 10). The builders are checked against those real
// vectors byte for byte (VideoSPSTests), so a synthetic fault differs from a real stream in exactly
// one field.
import Foundation
@testable import OpenCfMotoCore

struct H264BitWriter {
    private(set) var bits: [UInt8] = []

    mutating func u(_ n: Int, _ v: Int) {
        for i in stride(from: n - 1, through: 0, by: -1) { bits.append(UInt8((v >> i) & 1)) }
    }

    mutating func flag(_ b: Bool) { u(1, b ? 1 : 0) }

    mutating func ue(_ v: Int) {
        let x = v + 1
        var n = 0
        while (x >> (n + 1)) > 0 { n += 1 }
        u(n, 0)
        u(n + 1, x)
    }

    mutating func se(_ v: Int) { ue(v > 0 ? 2 * v - 1 : -2 * v) }

    /// The RBSP bytes: the bits, then (when `trailing`) rbsp_stop_one_bit and zero bits to a byte.
    func rbsp(trailing: Bool = true) -> [UInt8] {
        var b = bits
        if trailing { b.append(1) }
        while b.count % 8 != 0 { b.append(0) }
        return stride(from: 0, to: b.count, by: 8).map { i in b[i ..< i + 8].reduce(0) { ($0 << 1) | $1 } }
    }

    /// `header` + the RBSP with emulation-prevention bytes inserted (§7.4.1).
    func nal(header: UInt8, trailing: Bool = true) -> Data {
        var out: [UInt8] = [header]
        var zeros = 0
        for byte in rbsp(trailing: trailing) {
            if zeros >= 2, byte <= 3 {
                out.append(0x03)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return Data(out)
    }
}

enum H264Fixture {
    // MARK: Known-good vectors (contract section 10)

    /// SPS 800×384 of the CI simulator's VideoToolbox (passes every check at 800×384, ≤ 30 fps).
    static let vtSPS = Data([0x27, 0x42, 0xE0, 0x1F, 0xA9, 0x18, 0x19, 0x06, 0x36, 0x02, 0xD4, 0x08, 0x08, 0x08, 0xC2, 0xB5,
                             0xEF, 0x7C, 0x04])
    /// Its PPS (CAVLC, ids 0).
    static let vtPPS = Data([0x28, 0xDE, 0x09, 0xC8])
    /// Reference SPS 800×384 (POC 2, 1 ref, reorder 0).
    static let referenceSPS = Data([0x67, 0x42, 0xC0, 0x1F, 0xDA, 0x03, 0x20, 0xC6, 0x80, 0x78, 0x44, 0x23, 0x50])
    /// Wrong-size SPS (the repo's fake-source 1280×576 SPS; its VUI is truncated).
    static let wrongSizeSPS = Data([0x67, 0x42, 0x00, 0x1F, 0xDA, 0x01, 0x40, 0x12, 0x69, 0xA8])
    /// The fake source's PPS (CAVLC, pic_init_qp 29, no deblocking control).
    static let fakeSourcePPS = Data([0x68, 0xCE, 0x0D, 0x88])
    /// IDR slice: first_mb 0, slice_type 7 (I), pps 0, then payload.
    static let idrSlice = Data([0x65, 0x88, 0x84, 0x00, 0x10, 0x5A])
    /// P slice: first_mb 0, slice_type 5 (P), pps 0, then payload.
    static let pSlice = Data([0x41, 0x9A, 0x00, 0x21, 0x37])

    static let canvas800x384 = VideoCanvas(width: 800, height: 384)

    // MARK: Builders

    struct HRD {
        var cpbCountMinus1 = 0
        var bitRateScale = 0
        var cpbSizeScale = 10
        var bitRateValueMinus1 = 0
        var cpbSizeValueMinus1 = 0
        var cbr = false
        var initialCpbRemovalDelayLengthMinus1 = 23
        var cpbRemovalDelayLengthMinus1 = 23
        var dpbOutputDelayLengthMinus1 = 23
        var timeOffsetLength = 24

        func write(_ w: inout H264BitWriter) {
            w.ue(cpbCountMinus1)
            w.u(4, bitRateScale)
            w.u(4, cpbSizeScale)
            for _ in 0 ... max(cpbCountMinus1, 0) {
                w.ue(bitRateValueMinus1)
                w.ue(cpbSizeValueMinus1)
                w.flag(cbr)
            }
            w.u(5, initialCpbRemovalDelayLengthMinus1)
            w.u(5, cpbRemovalDelayLengthMinus1)
            w.u(5, dpbOutputDelayLengthMinus1)
            w.u(5, timeOffsetLength)
        }
    }

    struct VideoSignal {
        var format = 5
        var fullRange = false
        /// colour_primaries, transfer_characteristics, matrix_coefficients; nil = no colour description.
        var colour: (Int, Int, Int)? = (2, 2, 2)
    }

    struct BitstreamRestriction {
        var motionVectorsOverPicBoundaries = true
        var maxBytesPerPicDenom = 0
        var maxBitsPerMbDenom = 0
        var log2MaxMvLengthHorizontal = 16
        var log2MaxMvLengthVertical = 16
        var maxNumReorderFrames = 0
        var maxDecFrameBuffering = 1
    }

    struct VUI {
        /// aspect_ratio_idc (255 = Extended_SAR, written with `sar`); nil = no aspect ratio info.
        var aspectRatioIdc: Int?
        var sar = (width: 4, height: 3)
        /// overscan_appropriate_flag; nil = no overscan info.
        var overscanAppropriate: Bool?
        var videoSignal: VideoSignal?
        /// chroma_sample_loc_type_top_field / _bottom_field; nil = no chroma location info.
        var chromaLocation: (Int, Int)?
        /// num_units_in_tick, time_scale, fixed_frame_rate_flag; nil = no timing info.
        var timing: (unitsInTick: Int, timeScale: Int, fixed: Bool)?
        var nalHRD: HRD?
        var vclHRD: HRD?
        var lowDelayHRD = false
        var picStructPresent = false
        var restriction: BitstreamRestriction?

        func write(_ w: inout H264BitWriter) {
            w.flag(aspectRatioIdc != nil)
            if let idc = aspectRatioIdc {
                w.u(8, idc)
                if idc == 255 { w.u(16, sar.width); w.u(16, sar.height) }
            }
            w.flag(overscanAppropriate != nil)
            if let o = overscanAppropriate { w.flag(o) }
            w.flag(videoSignal != nil)
            if let v = videoSignal {
                w.u(3, v.format)
                w.flag(v.fullRange)
                w.flag(v.colour != nil)
                if let c = v.colour { w.u(8, c.0); w.u(8, c.1); w.u(8, c.2) }
            }
            w.flag(chromaLocation != nil)
            if let c = chromaLocation { w.ue(c.0); w.ue(c.1) }
            w.flag(timing != nil)
            if let t = timing { w.u(32, t.unitsInTick); w.u(32, t.timeScale); w.flag(t.fixed) }
            w.flag(nalHRD != nil)
            nalHRD?.write(&w)
            w.flag(vclHRD != nil)
            vclHRD?.write(&w)
            if nalHRD != nil || vclHRD != nil { w.flag(lowDelayHRD) }
            w.flag(picStructPresent)
            w.flag(restriction != nil)
            if let r = restriction {
                w.flag(r.motionVectorsOverPicBoundaries)
                w.ue(r.maxBytesPerPicDenom)
                w.ue(r.maxBitsPerMbDenom)
                w.ue(r.log2MaxMvLengthHorizontal)
                w.ue(r.log2MaxMvLengthVertical)
                w.ue(r.maxNumReorderFrames)
                w.ue(r.maxDecFrameBuffering)
            }
        }

        /// The VUI of `vtSPS`: square pixels, limited range, colour 2/2/2, a NAL HRD with placeholder
        /// values, no timing, no bitstream_restriction.
        static let videoToolbox = VUI(aspectRatioIdc: 1, videoSignal: VideoSignal(), nalHRD: HRD())
        /// The VUI of `referenceSPS`: only bitstream_restriction (reorder 0, buffering 1).
        static let reference = VUI(restriction: BitstreamRestriction())
    }

    /// A Baseline-family SPS; the defaults reproduce `vtSPS` byte for byte (header 0x27). Profiles with
    /// the High-profile chroma fields are not supported (use VideoSPSTests' builder for those).
    struct SPS {
        var header: UInt8 = 0x27
        var profile = 66
        var constraints = 0xE0
        var level = 31
        var spsId = 0
        var log2MaxFrameNumMinus4 = 1
        var pocType = 0
        var log2MaxPocLsbMinus4 = 3
        var maxNumRefFrames = 2
        var gapsInFrameNumAllowed = false
        var widthMbs = 50
        var heightMapUnits = 24
        var frameMbsOnly = true
        var direct8x8Inference = true
        /// left, right, top, bottom; nil = frame_cropping_flag 0.
        var crop: (Int, Int, Int, Int)?
        var vui: VUI? = .videoToolbox
        /// false: stop right after the last field (no rbsp trailing bits).
        var trailing = true

        /// The fields up to and including frame cropping (without vui_parameters_present_flag).
        func writeHead(_ w: inout H264BitWriter) {
            w.u(8, profile)
            w.u(8, constraints)
            w.u(8, level)
            w.ue(spsId)
            w.ue(log2MaxFrameNumMinus4)
            w.ue(pocType)
            if pocType == 0 { w.ue(log2MaxPocLsbMinus4) }
            if pocType == 1 { w.flag(false); w.se(-3); w.se(5); w.ue(2); w.se(1); w.se(-1) }
            w.ue(maxNumRefFrames)
            w.flag(gapsInFrameNumAllowed)
            w.ue(widthMbs - 1)
            w.ue(heightMapUnits - 1)
            w.flag(frameMbsOnly)
            if !frameMbsOnly { w.flag(false) } // mb_adaptive_frame_field_flag
            w.flag(direct8x8Inference)
            w.flag(crop != nil)
            if let c = crop { w.ue(c.0); w.ue(c.1); w.ue(c.2); w.ue(c.3) }
        }

        func nal() -> Data {
            var w = H264BitWriter()
            writeHead(&w)
            w.flag(vui != nil)
            vui?.write(&w)
            return w.nal(header: header, trailing: trailing)
        }

        /// `referenceSPS` byte for byte.
        static let reference = SPS(header: 0x67, constraints: 0xC0, log2MaxFrameNumMinus4: 0, pocType: 2, maxNumRefFrames: 1,
                                   vui: .reference)
    }

    /// A PPS; the defaults reproduce `vtPPS` byte for byte.
    struct PPS {
        var header: UInt8 = 0x28
        var ppsId = 0
        var spsId = 0
        var cabac = false
        var bottomFieldPicOrderInFramePresent = true
        var sliceGroupsMinus1 = 0
        /// slice_group_map_type (0–6) and what it needs; only written with slice groups.
        var sliceGroupMapType = 1
        var mapUnitsMinus1 = 3
        var l0Minus1 = 0
        var l1Minus1 = 0
        var weightedPred = false
        var weightedBipredIdc = 0
        var qpMinus26 = 2
        var qsMinus26 = 0
        var chromaQpIndexOffset = 0
        var deblockingFilterControl = true
        var constrainedIntraPred = false
        var redundantPicCnt = false
        /// false: stop right after the last field (no rbsp trailing bits).
        var trailing = true

        func nal() -> Data {
            var w = H264BitWriter()
            w.ue(ppsId)
            w.ue(spsId)
            w.flag(cabac)
            w.flag(bottomFieldPicOrderInFramePresent)
            w.ue(sliceGroupsMinus1)
            if sliceGroupsMinus1 > 0 {
                w.ue(sliceGroupMapType)
                switch sliceGroupMapType {
                case 0: for _ in 0 ... sliceGroupsMinus1 { w.ue(3) }
                case 2: for _ in 0 ..< sliceGroupsMinus1 { w.ue(0); w.ue(10) }
                case 3, 4, 5: w.flag(true); w.ue(7)
                case 6:
                    var idBits = 0
                    while (1 << idBits) < sliceGroupsMinus1 + 1 { idBits += 1 }
                    w.ue(mapUnitsMinus1)
                    for i in 0 ... mapUnitsMinus1 { w.u(idBits, i % (sliceGroupsMinus1 + 1)) }
                default: break
                }
            }
            w.ue(l0Minus1)
            w.ue(l1Minus1)
            w.flag(weightedPred)
            w.u(2, weightedBipredIdc)
            w.se(qpMinus26)
            w.se(qsMinus26)
            w.se(chromaQpIndexOffset)
            w.flag(deblockingFilterControl)
            w.flag(constrainedIntraPred)
            w.flag(redundantPicCnt)
            return w.nal(header: header, trailing: trailing)
        }
    }

    /// A slice NAL unit: header 0x65 (IDR) or 0x41, first_mb_in_slice, slice_type, pps id, then a few
    /// payload bits.
    static func slice(idr: Bool, sliceType: Int, firstMb: Int = 0, ppsId: Int = 0) -> Data {
        var w = H264BitWriter()
        w.ue(firstMb)
        w.ue(sliceType)
        w.ue(ppsId)
        w.u(8, 0x5A)
        return w.nal(header: idr ? 0x65 : 0x41)
    }

    /// An access unit with 4-byte start codes.
    static func au(_ nals: [Data]) -> Data { AnnexB.join(nals) }

    /// A valid IDR access unit for 800×384: vtSPS, vtPPS, IDR slice.
    static var validIDR: Data { au([vtSPS, vtPPS, idrSlice]) }
}
