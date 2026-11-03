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
    /// `start-code-3`: a 3-byte start code (only 4-byte start codes are allowed).
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
    /// step-0 placeholder: K implements rules 1–7 completely. Until then only empty access units,
    /// `requireKeyframe`, missing SPS / PPS and the SPS size are checked.
    public static func check(accessUnit: Data, canvas: VideoCanvas, requireKeyframe: Bool,
                             frameRate: Int = 8) -> [H264StreamIssue] {
        _ = frameRate
        let nals = AnnexB.nalUnits(annexB: accessUnit)
        guard !accessUnit.isEmpty, !nals.isEmpty else { return [.emptyAccessUnit] }
        let types = nals.compactMap { AnnexB.nalType($0) }
        let isIDR = types.contains(H264NALType.idrSlice.rawValue)
        var issues: [H264StreamIssue] = []
        if requireKeyframe, !isIDR { issues.append(.notIDR) }
        guard isIDR else { return issues }
        guard let spsNAL = nals.first(where: { AnnexB.nalType($0) == H264NALType.sps.rawValue }) else {
            issues.append(.missingSPS)
            if !types.contains(H264NALType.pps.rawValue) { issues.append(.missingPPS) }
            return issues
        }
        if !types.contains(H264NALType.pps.rawValue) { issues.append(.missingPPS) }
        guard let sps = H264SPS.parse(nal: spsNAL) else {
            issues.append(.spsUnparsable)
            return issues
        }
        if sps.width != canvas.width || sps.height != canvas.height {
            issues.append(.size(width: sps.width, height: sps.height))
        }
        return issues
    }

    /// The level_idc a background stream must carry for `canvas` at `frameRate`: 31 (level 3.1), or —
    /// when the canvas exceeds level 3.1's MaxFS (3,600 macroblocks) or MaxMBPS (108,000 macroblocks/s)
    /// at that rate — the lowest higher Baseline level (Table A-1) whose MaxFS and MaxMBPS fit.
    public static func expectedLevel(canvas: VideoCanvas, frameRate: Int) -> Int {
        _ = (canvas, frameRate)
        return 31 // step-0 placeholder: K implements
    }
}
