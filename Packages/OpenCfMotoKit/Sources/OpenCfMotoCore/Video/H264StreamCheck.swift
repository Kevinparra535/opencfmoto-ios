// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (design §3.3 "Stream check", §3.7 invariant 1): the bitstream rules every
// BACKGROUND encoder must meet before its first IDR reaches the dash. The engine runs the check on the
// probe IDR of every background candidate (vt-sw, cpu) and rejects the candidate on any issue, so a
// malformed or wrong-size SPS never reaches the dash. The rules are the common ground of the streams
// the CFMOTO dashes are known to decode (Android: constraint 0x00, POC 2, 1 ref; the CI simulator's
// VideoToolbox: 0xE0, POC 0, 2 refs): Baseline, level 3.1, the RLY 17 canvas, CAVLC, no reordering.

import Foundation

/// One rule an access unit breaks. `description` is the stable code written in the logs
/// (`sps=<code>,<code>` in `[bg] try …`, `sps: <codes>` in the rejection reason).
public enum H264StreamIssue: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// `empty-au`: no bytes, or no NAL unit at all.
    case emptyAccessUnit
    /// `start-code-3`: a 3-byte start code (only 4-byte start codes are allowed); also bytes before the
    /// first start code (a NAL unit without its `00 00 00 01`).
    case threeByteStartCode
    /// `nal-<type>`: a NAL type outside {1, 5, 7, 8} (SEI 6, AUD 9, filler 12, …).
    case nalType(UInt8)
    /// `no-idr`: a keyframe was required and the access unit has no IDR slice.
    case notIDR
    /// `mixed-slices`: IDR (5) and non-IDR (1) slices in one access unit.
    case mixedSlices
    /// `no-sps` / `no-pps`: an IDR access unit without its SPS / PPS.
    case missingSPS
    case missingPPS
    /// `repeated-ps`: more than one SPS or more than one PPS in an access unit.
    case repeatedParameterSet
    /// `idr-order`: an IDR access unit that does not start with SPS, PPS, IDR slice (`[7, 8, 5…]`).
    case badIDROrder
    /// `ps-without-idr`: SPS / PPS in an access unit without an IDR slice (incl. an AU of SPS/PPS only).
    case parameterSetsWithoutIDR
    /// `sps-unparsable` / `pps-unparsable`: present but not readable.
    case spsUnparsable
    case ppsUnparsable
    /// `profile-<n>`: profile_idc is not 66 (Baseline).
    case profile(Int)
    /// `level-<n>`: level_idc is not the expected level (`H264StreamCheck.expectedLevel`).
    case level(Int)
    /// `size-<w>x<h>`: the SPS picture size differs from the canvas.
    case size(width: Int, height: Int)
    /// `cropping`: frame_cropping_flag is set.
    case cropping
    /// `field-coding`: frame_mbs_only_flag is 0.
    case fieldCoding
    /// `poc-<n>`: pic_order_cnt_type is not 0 or 2.
    case pocType(Int)
    /// `refs-<n>`: max_num_ref_frames is above 2.
    case referenceFrames(Int)
    /// `reorder-<n>`: the VUI max_num_reorder_frames is present and not 0.
    case reorder(Int)
    /// `sps-id-<n>`: seq_parameter_set_id is not 0.
    case spsID(Int)
    /// `cabac`: entropy_coding_mode_flag is set.
    case cabac
    /// `slice-groups-<n>`: more than one slice group (FMO).
    case sliceGroups(Int)
    /// `pps-id-<n>` / `pps-sps-id-<n>`: the PPS id, or the SPS id it refers to, is not 0.
    case ppsID(Int)
    case ppsSPSID(Int)
    /// `slice-<P|B|I|SP|SI>`: a slice that is not I or P (the raw slice_type is kept).
    case sliceType(Int)
    /// `slice-unparsable`: a slice header that cannot be read as far as slice_type.
    case sliceUnparsable

    public var description: String {
        switch self {
        case .emptyAccessUnit: return "empty-au"
        case .threeByteStartCode: return "start-code-3"
        case let .nalType(t): return "nal-\(t)"
        case .notIDR: return "no-idr"
        case .mixedSlices: return "mixed-slices"
        case .missingSPS: return "no-sps"
        case .missingPPS: return "no-pps"
        case .repeatedParameterSet: return "repeated-ps"
        case .badIDROrder: return "idr-order"
        case .parameterSetsWithoutIDR: return "ps-without-idr"
        case .spsUnparsable: return "sps-unparsable"
        case .ppsUnparsable: return "pps-unparsable"
        case let .profile(p): return "profile-\(p)"
        case let .level(l): return "level-\(l)"
        case let .size(w, h): return "size-\(w)x\(h)"
        case .cropping: return "cropping"
        case .fieldCoding: return "field-coding"
        case let .pocType(t): return "poc-\(t)"
        case let .referenceFrames(n): return "refs-\(n)"
        case let .reorder(n): return "reorder-\(n)"
        case let .spsID(id): return "sps-id-\(id)"
        case .cabac: return "cabac"
        case let .sliceGroups(n): return "slice-groups-\(n)"
        case let .ppsID(id): return "pps-id-\(id)"
        case let .ppsSPSID(id): return "pps-sps-id-\(id)"
        case let .sliceType(t):
            let names = ["P", "B", "I", "SP", "SI"]
            return t >= 0 ? "slice-\(names[t % 5])" : "slice-\(t)"
        case .sliceUnparsable: return "slice-unparsable"
        }
    }
}

public enum H264StreamCheck {
    /// The highest max_num_ref_frames allowed (VideoToolbox writes 2).
    public static let maxReferenceFrames = 2

    /// Every rule `accessUnit` (Annex-B, as it would go on the wire) breaks for `canvas`; empty = OK.
    /// Issues are reported in the order of the rules below, each at most once:
    /// 1. start codes are 4-byte only; never an empty access unit;
    /// 2. NAL types in {1, 5, 7, 8}; no IDR and non-IDR slices together;
    /// 3. `requireKeyframe` → an IDR slice is present;
    /// 4. an IDR access unit starts `[7, 8, 5…]`, with exactly one SPS and one PPS; SPS / PPS never
    ///    appear without an IDR slice;
    /// 5. SPS: profile_idc 66; level_idc = `expectedLevel(canvas:frameRate:)`; size = the canvas;
    ///    no cropping; frame_mbs_only 1; POC type 0 or 2; max_num_ref_frames ≤ 2; VUI
    ///    max_num_reorder_frames 0 when present; seq_parameter_set_id 0;
    /// 6. PPS: CAVLC; one slice group; pic_parameter_set_id 0; its seq_parameter_set_id 0;
    /// 7. every slice is I or P.
    /// `frameRate`: the rate the encoder was configured for (the background cap by default).
    ///
    /// Details:
    /// - an access unit without any NAL unit (no bytes, no start code, or start codes only) gives
    ///   `[empty-au]` alone; `start-code-3` also covers bytes before the first start code (a NAL unit
    ///   not introduced by `00 00 00 01`, e.g. AVCC length prefixes); start codes followed by nothing
    ///   are skipped, as `AnnexB.nalUnits` does;
    /// - `nal-<t>` once per distinct type, in order of appearance;
    /// - an IDR access unit reports `no-sps`, `no-pps`, `repeated-ps` for its parameter sets, and
    ///   `idr-order` only when it has exactly one SPS and one PPS but does not start SPS, PPS, IDR slice
    ///   — the order is read over the NAL units of the allowed types (a disallowed one is reported by
    ///   rule 2 already);
    /// - rules 5 and 6 read the first SPS / PPS of the access unit (`sps-unparsable` /
    ///   `pps-unparsable` when it cannot be read), also in an access unit without an IDR slice;
    /// - rule 7 reads every slice (types 1 and 5); a slice_type above 9 does not exist and is
    ///   `slice-unparsable`.
    public static func check(accessUnit: Data, canvas: VideoCanvas, requireKeyframe: Bool,
                             frameRate: Int = 8) -> [H264StreamIssue] {
        let bytes = [UInt8](accessUnit)
        let codes = startCodes(bytes)
        var nals: [ArraySlice<UInt8>] = []
        var shortStartCode = false
        for (n, code) in codes.enumerated() {
            let end = n + 1 < codes.count ? codes[n + 1].codeStart : bytes.count
            guard end > code.payloadStart else { continue }
            nals.append(bytes[code.payloadStart ..< end])
            if code.payloadStart - code.codeStart != 4 { shortStartCode = true }
        }
        guard !nals.isEmpty else { return [.emptyAccessUnit] }

        var issues: [H264StreamIssue] = []
        func report(_ issue: H264StreamIssue) {
            if !issues.contains(issue) { issues.append(issue) }
        }

        // 1. Framing.
        if shortStartCode || (codes.first?.codeStart ?? 0) > 0 { report(.threeByteStartCode) }

        // 2. NAL types.
        let types = nals.map { $0[$0.startIndex] & 0x1F }
        for t in types where !allowedNALTypes.contains(t) { report(.nalType(t)) }
        let hasIDR = types.contains(H264NALType.idrSlice.rawValue)
        if hasIDR, types.contains(H264NALType.nonIDRSlice.rawValue) { report(.mixedSlices) }

        // 3. Keyframe.
        if requireKeyframe, !hasIDR { report(.notIDR) }

        // 4. Parameter sets and their place.
        let spsCount = types.filter { $0 == H264NALType.sps.rawValue }.count
        let ppsCount = types.filter { $0 == H264NALType.pps.rawValue }.count
        if hasIDR {
            if spsCount == 0 { report(.missingSPS) }
            if ppsCount == 0 { report(.missingPPS) }
            if spsCount > 1 || ppsCount > 1 { report(.repeatedParameterSet) }
            if spsCount == 1, ppsCount == 1 {
                let order = types.filter { allowedNALTypes.contains($0) }
                if Array(order.prefix(3)) != [H264NALType.sps.rawValue, H264NALType.pps.rawValue, H264NALType.idrSlice.rawValue] {
                    report(.badIDROrder)
                }
            }
        } else if spsCount > 0 || ppsCount > 0 {
            report(.parameterSetsWithoutIDR)
        }

        // 5. SPS.
        if let spsNAL = nals.first(where: { $0[$0.startIndex] & 0x1F == H264NALType.sps.rawValue }) {
            if let sps = H264SPS.parse(nal: Data(spsNAL)) {
                if sps.profileIdc != 66 { report(.profile(sps.profileIdc)) }
                if sps.levelIdc != expectedLevel(canvas: canvas, frameRate: frameRate) { report(.level(sps.levelIdc)) }
                if sps.width != canvas.width || sps.height != canvas.height {
                    report(.size(width: sps.width, height: sps.height))
                }
                if sps.frameCropping { report(.cropping) }
                if !sps.frameMbsOnly { report(.fieldCoding) }
                if sps.pocType != 0, sps.pocType != 2 { report(.pocType(sps.pocType)) }
                if sps.maxNumRefFrames > maxReferenceFrames { report(.referenceFrames(sps.maxNumRefFrames)) }
                if let reorder = sps.maxNumReorderFrames, reorder != 0 { report(.reorder(reorder)) }
                if sps.seqParameterSetId != 0 { report(.spsID(sps.seqParameterSetId)) }
            } else {
                report(.spsUnparsable)
            }
        }

        // 6. PPS.
        if let ppsNAL = nals.first(where: { $0[$0.startIndex] & 0x1F == H264NALType.pps.rawValue }) {
            if let pps = H264PPS.parse(nal: Data(ppsNAL)) {
                if pps.entropyCodingCABAC { report(.cabac) }
                if pps.numSliceGroups != 1 { report(.sliceGroups(pps.numSliceGroups)) }
                if pps.picParameterSetId != 0 { report(.ppsID(pps.picParameterSetId)) }
                if pps.seqParameterSetId != 0 { report(.ppsSPSID(pps.seqParameterSetId)) }
            } else {
                report(.ppsUnparsable)
            }
        }

        // 7. Slice types.
        for nal in nals {
            let t = nal[nal.startIndex] & 0x1F
            guard t == H264NALType.nonIDRSlice.rawValue || t == H264NALType.idrSlice.rawValue else { continue }
            guard let sliceType = readSliceType(slice: nal) else {
                report(.sliceUnparsable)
                continue
            }
            if sliceType % 5 != 0, sliceType % 5 != 2 { report(.sliceType(sliceType)) } // not P (0) or I (2)
        }
        return issues
    }

    /// The level_idc a background stream must carry for `canvas` at `frameRate`: 31 (level 3.1), or —
    /// when the canvas exceeds level 3.1's MaxFS (3,600 macroblocks) or MaxMBPS (108,000 macroblocks/s)
    /// at that rate — the lowest higher Baseline level (Table A-1) whose MaxFS and MaxMBPS fit.
    /// The frame size in macroblocks rounds partial macroblocks up; a negative rate counts as 0; a canvas
    /// beyond every level gives the highest level (62).
    public static func expectedLevel(canvas: VideoCanvas, frameRate: Int) -> Int {
        let widthMbs = (min(max(canvas.width, 0), 1 << 20) + 15) / 16
        let heightMbs = (min(max(canvas.height, 0), 1 << 20) + 15) / 16
        let frameMbs = widthMbs * heightMbs
        let (perSecond, overflow) = frameMbs.multipliedReportingOverflow(by: max(frameRate, 0))
        for level in levelLimits where frameMbs <= level.maxFrameMbs && !overflow && perSecond <= level.maxMbsPerSecond {
            return level.idc
        }
        return levelLimits[levelLimits.count - 1].idc
    }

    // MARK: - Private

    /// NAL unit types a dash access unit may carry: non-IDR slice, IDR slice, SPS, PPS.
    private static let allowedNALTypes: Set<UInt8> = [
        H264NALType.nonIDRSlice.rawValue, H264NALType.idrSlice.rawValue, H264NALType.sps.rawValue, H264NALType.pps.rawValue,
    ]

    /// H.264 Table A-1 from level 3.1 up: level_idc, MaxMBPS (macroblocks/s), MaxFS (macroblocks).
    private static let levelLimits: [(idc: Int, maxMbsPerSecond: Int, maxFrameMbs: Int)] = [
        (31, 108_000, 3_600), (32, 216_000, 5_120), (40, 245_760, 8_192), (41, 245_760, 8_192),
        (42, 522_240, 8_704), (50, 589_824, 22_080), (51, 983_040, 36_864), (52, 2_073_600, 36_864),
        (60, 4_177_920, 139_264), (61, 8_355_840, 139_264), (62, 16_711_680, 139_264),
    ]

    /// Every `00 00 01` of `bytes`, scanning forward: where its start code begins (one byte earlier
    /// when a zero precedes it, i.e. a 4-byte `00 00 00 01`) and where the NAL unit after it begins.
    private static func startCodes(_ bytes: [UInt8]) -> [(codeStart: Int, payloadStart: Int)] {
        var out: [(codeStart: Int, payloadStart: Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                out.append((i > 0 && bytes[i - 1] == 0 ? i - 1 : i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        return out
    }

    /// slice_type of a slice NAL unit (header byte first): first_mb_in_slice ue(v), then slice_type
    /// ue(v) (§7.3.3); nil when unreadable or above 9.
    private static func readSliceType(slice nal: ArraySlice<UInt8>) -> Int? {
        let header = Array(nal.dropFirst().prefix(24)) // two Exp-Golomb codes fit easily
        var r = H264BitReader(rbsp: H264SPS.removeEmulationPrevention(header))
        guard r.ue() != nil, let sliceType = r.ue(), sliceType <= 9 else { return nil }
        return sliceType
    }
}
