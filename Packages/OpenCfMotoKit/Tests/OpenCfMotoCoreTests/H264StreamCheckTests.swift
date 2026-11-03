// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0: H264StreamCheck, the rules a background encoder's probe IDR must meet before
// anything of it reaches the dash. Every fault is built from the dash-proven VideoToolbox stream
// (H264Fixture: the builders reproduce it byte for byte) with exactly one field changed, so each test
// expects exactly its own issue code.
import XCTest
@testable import OpenCfMotoCore

final class H264StreamCheckTests: XCTestCase {
    private typealias F = H264Fixture
    private let canvas = H264Fixture.canvas800x384

    private func check(_ nals: [Data], keyframe: Bool = true, canvas: VideoCanvas? = nil, fps: Int = 8) -> [H264StreamIssue] {
        H264StreamCheck.check(accessUnit: F.au(nals), canvas: canvas ?? self.canvas, requireKeyframe: keyframe, frameRate: fps)
    }

    /// An IDR access unit with `sps` / `pps` changed from the VideoToolbox ones.
    private func idr(sps: F.SPS = F.SPS(), pps: F.PPS = F.PPS()) -> [Data] { [sps.nal(), pps.nal(), F.idrSlice] }

    private static let sc4: [UInt8] = [0, 0, 0, 1]
    private static let sc3: [UInt8] = [0, 0, 1]

    /// Raw bytes, for access units with hand-made start codes.
    private func raw(_ parts: [UInt8]...) -> Data { Data(parts.joined()) }

    // MARK: Valid streams

    func testValidAccessUnitsPass() {
        XCTAssertEqual(H264StreamCheck.check(accessUnit: F.validIDR, canvas: canvas, requireKeyframe: true), [])
        // The reference (Android-like) SPS: POC 2, 1 ref, reorder 0.
        XCTAssertEqual(check([F.referenceSPS, F.vtPPS, F.idrSlice]), [])
        XCTAssertEqual(check([F.referenceSPS, F.fakeSourcePPS, F.idrSlice]), [])
        // A P frame, when no keyframe is required; an IDR made of two slices; built slices I and P.
        XCTAssertEqual(check([F.pSlice], keyframe: false), [])
        XCTAssertEqual(check([F.vtSPS, F.vtPPS, F.idrSlice, F.idrSlice]), [])
        XCTAssertEqual(check([F.vtSPS, F.vtPPS, F.slice(idr: true, sliceType: 2)]), [])
        XCTAssertEqual(check([F.slice(idr: false, sliceType: 0)], keyframe: false), [])
        // An IDR is fine where no keyframe is required.
        XCTAssertEqual(check(idr(), keyframe: false), [])
        // The default frame rate is the background cap (8).
        XCTAssertEqual(H264StreamCheck.check(accessUnit: F.validIDR, canvas: canvas, requireKeyframe: true, frameRate: 30), [])
    }

    // MARK: Rule 1: framing

    func testEmptyAccessUnit() {
        XCTAssertEqual(H264StreamCheck.check(accessUnit: Data(), canvas: canvas, requireKeyframe: true), [.emptyAccessUnit])
        XCTAssertEqual(H264StreamCheck.check(accessUnit: Data([0, 0, 0, 1]), canvas: canvas, requireKeyframe: false),
                       [.emptyAccessUnit], "a start code alone")
        XCTAssertEqual(H264StreamCheck.check(accessUnit: Data([0, 0, 0, 1, 0, 0, 0, 1]), canvas: canvas, requireKeyframe: false),
                       [.emptyAccessUnit], "start codes only")
        XCTAssertEqual(H264StreamCheck.check(accessUnit: Data([0x65, 0x88, 0x84]), canvas: canvas, requireKeyframe: true),
                       [.emptyAccessUnit], "bytes without any start code")
        XCTAssertEqual(H264StreamIssue.emptyAccessUnit.description, "empty-au")
    }

    func testThreeByteStartCodes() {
        let threeByte = raw(Self.sc3, [UInt8](F.vtSPS), Self.sc3, [UInt8](F.vtPPS), Self.sc3, [UInt8](F.idrSlice))
        XCTAssertEqual(H264StreamCheck.check(accessUnit: threeByte, canvas: canvas, requireKeyframe: true), [.threeByteStartCode])
        // One 3-byte start code among 4-byte ones is enough.
        let mixed = raw(Self.sc4, [UInt8](F.vtSPS), Self.sc4, [UInt8](F.vtPPS), Self.sc3, [UInt8](F.idrSlice))
        XCTAssertEqual(H264StreamCheck.check(accessUnit: mixed, canvas: canvas, requireKeyframe: true), [.threeByteStartCode])
        // Bytes before the first start code (a NAL unit without its 00 00 00 01), e.g. a leading zero.
        let leading = raw([0x00], [UInt8](F.validIDR))
        XCTAssertEqual(H264StreamCheck.check(accessUnit: leading, canvas: canvas, requireKeyframe: true), [.threeByteStartCode])
        let garbage = raw([0x12, 0x34], [UInt8](F.validIDR))
        XCTAssertEqual(H264StreamCheck.check(accessUnit: garbage, canvas: canvas, requireKeyframe: true), [.threeByteStartCode])
        XCTAssertEqual(H264StreamIssue.threeByteStartCode.description, "start-code-3")
    }

    func testStartCodesWithNothingAfterThemAreSkipped() {
        // An extra start code (no NAL unit) between two NAL units is no issue, as AnnexB.nalUnits skips it.
        let au = raw(Self.sc4, [UInt8](F.vtSPS), Self.sc4, Self.sc4, [UInt8](F.vtPPS), Self.sc4, [UInt8](F.idrSlice))
        XCTAssertEqual(H264StreamCheck.check(accessUnit: au, canvas: canvas, requireKeyframe: true), [])
    }

    // MARK: Rule 2: NAL types

    func testSEIIsRejected() {
        let sei = Data([0x06, 0x05, 0x01, 0x80])
        XCTAssertEqual(check([F.vtSPS, F.vtPPS, sei, F.idrSlice]), [.nalType(6)])
        XCTAssertEqual(check([F.vtSPS, F.vtPPS, sei, sei, F.idrSlice]), [.nalType(6)], "each issue at most once")
        XCTAssertEqual(H264StreamIssue.nalType(6).description, "nal-6")
    }

    func testOtherNALTypesAreRejectedInOrderOfAppearance() {
        let aud = Data([0x09, 0xF0]), filler = Data([0x0C, 0xFF, 0xFF, 0x80]), endOfSeq = Data([0x0A])
        // An access unit delimiter in front does not also count as a wrong IDR order (rule 2 reports it).
        XCTAssertEqual(check([aud, F.vtSPS, F.vtPPS, F.idrSlice]), [.nalType(9)])
        XCTAssertEqual(check([F.vtSPS, F.vtPPS, F.idrSlice, filler, aud, endOfSeq]), [.nalType(12), .nalType(9), .nalType(10)])
        XCTAssertEqual(H264StreamIssue.nalType(12).description, "nal-12")
    }

    func testMixedSlices() {
        XCTAssertEqual(check([F.vtSPS, F.vtPPS, F.idrSlice, F.pSlice]), [.mixedSlices])
        XCTAssertEqual(H264StreamIssue.mixedSlices.description, "mixed-slices")
    }

    // MARK: Rule 3: keyframe

    func testKeyframeRequired() {
        XCTAssertEqual(check([F.pSlice]), [.notIDR])
        XCTAssertEqual(check([F.pSlice], keyframe: false), [])
        XCTAssertEqual(H264StreamIssue.notIDR.description, "no-idr")
    }

    // MARK: Rule 4: parameter sets and their place

    func testMissingParameterSets() {
        XCTAssertEqual(check([F.vtSPS, F.idrSlice]), [.missingPPS])
        XCTAssertEqual(check([F.vtPPS, F.idrSlice]), [.missingSPS])
        XCTAssertEqual(check([F.idrSlice]), [.missingSPS, .missingPPS])
        XCTAssertEqual([H264StreamIssue.missingSPS, .missingPPS].map(\.description), ["no-sps", "no-pps"])
    }

    func testRepeatedParameterSets() {
        XCTAssertEqual(check([F.vtSPS, F.vtSPS, F.vtPPS, F.idrSlice]), [.repeatedParameterSet])
        XCTAssertEqual(check([F.vtSPS, F.vtPPS, F.vtPPS, F.idrSlice]), [.repeatedParameterSet])
        XCTAssertEqual(check([F.vtSPS, F.vtPPS, F.idrSlice, F.vtSPS, F.vtPPS]), [.repeatedParameterSet])
        XCTAssertEqual(check([F.vtPPS, F.vtPPS, F.idrSlice]), [.missingSPS, .repeatedParameterSet])
        XCTAssertEqual(H264StreamIssue.repeatedParameterSet.description, "repeated-ps")
    }

    func testIDROrder() {
        XCTAssertEqual(check([F.vtPPS, F.vtSPS, F.idrSlice]), [.badIDROrder])
        XCTAssertEqual(check([F.vtSPS, F.idrSlice, F.vtPPS]), [.badIDROrder])
        XCTAssertEqual(check([F.idrSlice, F.vtSPS, F.vtPPS]), [.badIDROrder])
        XCTAssertEqual(H264StreamIssue.badIDROrder.description, "idr-order")
    }

    func testParameterSetsWithoutIDR() {
        XCTAssertEqual(check([F.vtSPS, F.vtPPS], keyframe: false), [.parameterSetsWithoutIDR], "an AU of SPS/PPS only")
        XCTAssertEqual(check([F.vtSPS, F.vtPPS]), [.notIDR, .parameterSetsWithoutIDR])
        XCTAssertEqual(check([F.vtSPS, F.vtPPS, F.pSlice], keyframe: false), [.parameterSetsWithoutIDR])
        XCTAssertEqual(check([F.vtPPS, F.pSlice], keyframe: false), [.parameterSetsWithoutIDR])
        XCTAssertEqual(H264StreamIssue.parameterSetsWithoutIDR.description, "ps-without-idr")
    }

    // MARK: Rule 5: SPS

    func testWrongCanvas() {
        // The contract's wrong-size vector (1280×576).
        XCTAssertTrue(check([F.wrongSizeSPS, F.vtPPS, F.idrSlice]).contains(.size(width: 1280, height: 576)))
        // One dimension off at a time, and the same SPS against the canvas it was made for.
        XCTAssertEqual(check(idr(sps: F.SPS(widthMbs: 49))), [.size(width: 784, height: 384)])
        XCTAssertEqual(check(idr(sps: F.SPS(heightMapUnits: 59))), [.size(width: 800, height: 944)])
        XCTAssertEqual(check(idr(sps: F.SPS(heightMapUnits: 59)), canvas: VideoCanvas(width: 800, height: 944)), [])
        XCTAssertEqual(H264StreamIssue.size(width: 1280, height: 576).description, "size-1280x576")
    }

    func testCropping() {
        // frame_cropping_flag with zero offsets: the size is still the canvas, the flag alone is the issue.
        XCTAssertEqual(check(idr(sps: F.SPS(crop: (0, 0, 0, 0)))), [.cropping])
        // A coded 800×400 cropped to 800×384 is just as wrong.
        XCTAssertEqual(check(idr(sps: F.SPS(heightMapUnits: 25, crop: (0, 0, 0, 8)))), [.cropping])
        XCTAssertEqual(H264StreamIssue.cropping.description, "cropping")
    }

    func testProfile() {
        XCTAssertEqual(check(idr(sps: F.SPS(profile: 77))), [.profile(77)])
        XCTAssertEqual(H264StreamIssue.profile(77).description, "profile-77")
    }

    func testLevel() {
        XCTAssertEqual(check(idr(sps: F.SPS(level: 30))), [.level(30)])
        XCTAssertEqual(check(idr(sps: F.SPS(level: 40))), [.level(40)])
        // 800×944 needs level 3.2 at 60 fps: a level 3.1 SPS is then the wrong one.
        let tall = VideoCanvas(width: 800, height: 944)
        XCTAssertEqual(check(idr(sps: F.SPS(heightMapUnits: 59)), canvas: tall, fps: 60), [.level(31)])
        XCTAssertEqual(check(idr(sps: F.SPS(level: 32, heightMapUnits: 59)), canvas: tall, fps: 60), [])
        XCTAssertEqual(H264StreamIssue.level(22).description, "level-22")
    }

    func testFieldCoding() {
        // frame_mbs_only 0 with 12 map units of 32 lines: still 800×384.
        XCTAssertEqual(check(idr(sps: F.SPS(heightMapUnits: 12, frameMbsOnly: false))), [.fieldCoding])
        XCTAssertEqual(H264StreamIssue.fieldCoding.description, "field-coding")
    }

    func testPOCType() {
        XCTAssertEqual(check(idr(sps: F.SPS(pocType: 1))), [.pocType(1)])
        XCTAssertEqual(check(idr(sps: F.SPS(pocType: 2))), [], "POC type 2 is fine (the Android stream)")
        XCTAssertEqual(H264StreamIssue.pocType(1).description, "poc-1")
    }

    func testReferenceFrames() {
        XCTAssertEqual(H264StreamCheck.maxReferenceFrames, 2)
        XCTAssertEqual(check(idr(sps: F.SPS(maxNumRefFrames: 3))), [.referenceFrames(3)])
        XCTAssertEqual(check(idr(sps: F.SPS(maxNumRefFrames: 0))), [])
        XCTAssertEqual(H264StreamIssue.referenceFrames(3).description, "refs-3")
    }

    func testReorder() {
        let reorder1 = F.VUI(restriction: .init(maxNumReorderFrames: 1, maxDecFrameBuffering: 2))
        XCTAssertEqual(check(idr(sps: F.SPS(vui: reorder1))), [.reorder(1)])
        // Reorder 0 is fine; no VUI or no bitstream_restriction is fine (VideoToolbox writes none).
        XCTAssertEqual(check(idr(sps: F.SPS(vui: F.VUI(restriction: .init(maxNumReorderFrames: 0))))), [])
        XCTAssertEqual(check(idr(sps: F.SPS(vui: nil))), [])
        XCTAssertEqual(H264StreamIssue.reorder(1).description, "reorder-1")
    }

    func testSPSID() {
        XCTAssertEqual(check(idr(sps: F.SPS(spsId: 1))), [.spsID(1)])
        XCTAssertEqual(H264StreamIssue.spsID(1).description, "sps-id-1")
    }

    func testUnparsableSPS() {
        XCTAssertEqual(check([Data([0x67, 0x42]), F.vtPPS, F.idrSlice]), [.spsUnparsable])
        XCTAssertEqual(H264StreamIssue.spsUnparsable.description, "sps-unparsable")
    }

    // MARK: Rule 6: PPS

    func testCABAC() {
        XCTAssertEqual(check(idr(pps: F.PPS(cabac: true))), [.cabac])
        XCTAssertEqual(H264StreamIssue.cabac.description, "cabac")
    }

    func testSliceGroups() {
        XCTAssertEqual(check(idr(pps: F.PPS(sliceGroupsMinus1: 1))), [.sliceGroups(2)])
        XCTAssertEqual(H264StreamIssue.sliceGroups(2).description, "slice-groups-2")
    }

    func testPPSIDs() {
        XCTAssertEqual(check(idr(pps: F.PPS(ppsId: 1))), [.ppsID(1)])
        XCTAssertEqual(check(idr(pps: F.PPS(spsId: 1))), [.ppsSPSID(1)])
        XCTAssertEqual([H264StreamIssue.ppsID(1), .ppsSPSID(1)].map(\.description), ["pps-id-1", "pps-sps-id-1"])
    }

    func testUnparsablePPS() {
        XCTAssertEqual(check([F.vtSPS, Data([0x28]), F.idrSlice]), [.ppsUnparsable])
        XCTAssertEqual(check([F.vtSPS, F.PPS(sliceGroupsMinus1: 1, sliceGroupMapType: 7).nal(), F.idrSlice]), [.ppsUnparsable])
        XCTAssertEqual(H264StreamIssue.ppsUnparsable.description, "pps-unparsable")
    }

    // MARK: Rule 7: slices

    func testBSlice() {
        let b = F.slice(idr: false, sliceType: 1)
        XCTAssertEqual(check([b], keyframe: false), [.sliceType(1)])
        XCTAssertEqual(H264StreamIssue.sliceType(1).description, "slice-B")
        // slice_type 6 (every slice of the picture B): the raw value is kept, the name from % 5.
        XCTAssertEqual(check([F.slice(idr: false, sliceType: 6)], keyframe: false), [.sliceType(6)])
        XCTAssertEqual(H264StreamIssue.sliceType(6).description, "slice-B")
        // Several B slices: once.
        XCTAssertEqual(check([b, b], keyframe: false), [.sliceType(1)])
    }

    func testSwitchingSlicesAreRejectedAndIPAccepted() {
        XCTAssertEqual(check([F.vtSPS, F.vtPPS, F.slice(idr: true, sliceType: 4)]), [.sliceType(4)])
        XCTAssertEqual(check([F.slice(idr: false, sliceType: 8)], keyframe: false), [.sliceType(8)])
        XCTAssertEqual([H264StreamIssue.sliceType(4), .sliceType(8), .sliceType(3), .sliceType(0), .sliceType(7)].map(\.description),
                       ["slice-SI", "slice-SP", "slice-SP", "slice-P", "slice-I"])
        for type in [0, 2, 5, 7] {
            XCTAssertEqual(check([F.slice(idr: false, sliceType: type)], keyframe: false), [], "slice_type \(type)")
        }
    }

    func testUnparsableSlice() {
        XCTAssertEqual(check([F.vtSPS, F.vtPPS, Data([0x65])]), [.sliceUnparsable], "a slice NAL without a header")
        XCTAssertEqual(check([Data([0x41, 0x00, 0x00, 0x00])], keyframe: false), [.sliceUnparsable], "runaway Exp-Golomb")
        XCTAssertEqual(check([F.slice(idr: false, sliceType: 12)], keyframe: false), [.sliceUnparsable], "slice_type 12 does not exist")
        XCTAssertEqual(H264StreamIssue.sliceUnparsable.description, "slice-unparsable")
    }

    // MARK: Order and uniqueness

    func testIssuesComeInRuleOrderEachOnce() {
        let sps = F.SPS(profile: 77, level: 30, spsId: 2, pocType: 1, maxNumRefFrames: 4, widthMbs: 40, crop: (0, 0, 0, 0),
                        vui: F.VUI(restriction: .init(maxNumReorderFrames: 3, maxDecFrameBuffering: 3)))
        let pps = F.PPS(ppsId: 1, spsId: 2, cabac: true, sliceGroupsMinus1: 2)
        let sei = Data([0x06, 0x05, 0x01, 0x80])
        let au = raw(Self.sc3, [UInt8](sei), Self.sc4, [UInt8](pps.nal()), Self.sc4, [UInt8](sps.nal()), Self.sc4, [UInt8](F.idrSlice),
                     Self.sc4, [UInt8](F.slice(idr: true, sliceType: 1)), Self.sc4, [UInt8](F.pSlice))
        XCTAssertEqual(H264StreamCheck.check(accessUnit: au, canvas: canvas, requireKeyframe: true), [
            .threeByteStartCode, .nalType(6), .mixedSlices, .badIDROrder,
            .profile(77), .level(30), .size(width: 640, height: 384), .cropping, .pocType(1), .referenceFrames(4), .reorder(3),
            .spsID(2),
            .cabac, .sliceGroups(3), .ppsID(1), .ppsSPSID(2),
            .sliceType(1),
        ])
        // An SPS that parses and a PPS that does not: the SPS rules (5) come before pps-unparsable (6).
        XCTAssertEqual(check([F.SPS(level: 30).nal(), Data([0x28]), F.idrSlice]), [.level(30), .ppsUnparsable])
    }

    // MARK: expectedLevel

    func testExpectedLevel() {
        // Every dash canvas at up to 30 fps: level 3.1.
        for (w, h) in [(800, 384), (800, 944), (1280, 576), (544, 512), (1024, 592), (800, 480)] {
            for fps in [1, 8, 15, 30] {
                XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: VideoCanvas(width: w, height: h), frameRate: fps), 31, "\(w)x\(h)@\(fps)")
            }
        }
        // 1280×720 = 3,600 MBs: exactly level 3.1's MaxFS; 30 fps = 108,000 MB/s, exactly its MaxMBPS.
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: VideoCanvas(width: 1280, height: 720), frameRate: 30), 31)
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: VideoCanvas(width: 1280, height: 720), frameRate: 31), 32)
        // A frame above 3,600 MBs needs 3.2 even at 1 fps (MaxFS 5,120).
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: VideoCanvas(width: 1296, height: 720), frameRate: 1), 32)
        // 800×944 at 60 fps: 177,000 MB/s → 3.2; at 80 fps 236,000 → 4.0; at 100 fps 295,000 → 4.2.
        let tall = VideoCanvas(width: 800, height: 944)
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: tall, frameRate: 60), 32)
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: tall, frameRate: 80), 40)
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: tall, frameRate: 100), 42)
        // Larger frames: 1080p (8,160 MBs) → 4.0, 2048×1088 (8,704) → 4.2, 4K (32,400) → 5.1, 8K → 6.0.
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: VideoCanvas(width: 1920, height: 1080), frameRate: 30), 40)
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: VideoCanvas(width: 2048, height: 1088), frameRate: 30), 42)
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: VideoCanvas(width: 3840, height: 2160), frameRate: 30), 51)
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: VideoCanvas(width: 8192, height: 4320), frameRate: 30), 60)
        // Beyond every level, and degenerate input: no trap.
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: VideoCanvas(width: 16384, height: 16384), frameRate: 30), 62)
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: VideoCanvas(width: Int.max, height: Int.max), frameRate: Int.max), 62)
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: VideoCanvas(width: 800, height: 384), frameRate: -5), 31)
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: VideoCanvas(width: -1, height: 0), frameRate: 8), 31)
        // A partial macroblock counts as a whole one: 1281×720 is 81 × 45 = 3,645 MBs.
        XCTAssertEqual(H264StreamCheck.expectedLevel(canvas: VideoCanvas(width: 1281, height: 720), frameRate: 1), 32)
    }
}
