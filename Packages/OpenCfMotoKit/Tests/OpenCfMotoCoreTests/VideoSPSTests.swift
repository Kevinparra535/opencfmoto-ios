// SPDX-License-Identifier: AGPL-3.0-or-later
// H264SPS: the picture size of an SPS (used by the mirror host to drop IDRs encoded for another
// canvas, MP-3). Vectors: the repo's fake-source SPS decoded by hand (Baseline L3.1, 1280×576) and
// SPSs built bit by bit below (Exp-Golomb + emulation prevention).
import XCTest
@testable import OpenCfMotoCore

/// Builds SPS NAL units bit by bit (test only).
private struct SPSBuilder {
    private var bits: [UInt8] = []

    mutating func u(_ n: Int, _ v: Int) {
        for i in stride(from: n - 1, through: 0, by: -1) { bits.append(UInt8((v >> i) & 1)) }
    }

    mutating func ue(_ v: Int) {
        let x = v + 1
        var n = 0
        while (x >> (n + 1)) > 0 { n += 1 }
        u(n, 0)
        u(n + 1, x)
    }

    mutating func se(_ v: Int) { ue(v > 0 ? 2 * v - 1 : -2 * v) }

    /// NAL header 0x67 + RBSP (trailing bits) with emulation-prevention bytes inserted.
    func nal() -> Data {
        var b = bits + [1]
        while b.count % 8 != 0 { b.append(0) }
        var rbsp: [UInt8] = []
        for i in stride(from: 0, to: b.count, by: 8) {
            rbsp.append(b[i ..< i + 8].reduce(0) { ($0 << 1) | $1 })
        }
        var out: [UInt8] = [0x67]
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 {
                out.append(0x03)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return Data(out)
    }

    /// A Baseline-style SPS (profile 66 or 77) for `widthMbs × heightMapUnits`.
    static func baseline(profile: Int = 66, constraints: Int = 0xC0, level: Int = 31, spsId: Int = 0, widthMbs: Int,
                         heightMapUnits: Int, frameMbsOnly: Bool = true, crop: (Int, Int, Int, Int)? = nil,
                         pocType: Int = 2) -> Data {
        var s = SPSBuilder()
        s.u(8, profile); s.u(8, constraints); s.u(8, level)
        s.ue(spsId)             // seq_parameter_set_id
        s.ue(0)                 // log2_max_frame_num_minus4
        s.ue(pocType)
        if pocType == 0 { s.ue(2) }
        if pocType == 1 { s.u(1, 0); s.se(-3); s.se(5); s.ue(2); s.se(1); s.se(-1) }
        s.ue(1)                 // max_num_ref_frames
        s.u(1, 0)               // gaps_in_frame_num_value_allowed_flag
        s.ue(widthMbs - 1)
        s.ue(heightMapUnits - 1)
        s.u(1, frameMbsOnly ? 1 : 0)
        if !frameMbsOnly { s.u(1, 0) }
        s.u(1, 1)               // direct_8x8_inference_flag
        if let c = crop {
            s.u(1, 1); s.ue(c.0); s.ue(c.1); s.ue(c.2); s.ue(c.3)
        } else {
            s.u(1, 0)
        }
        s.u(1, 0)               // vui_parameters_present_flag
        return s.nal()
    }
}

final class VideoSPSTests: XCTestCase {
    func testRepoFakeSourceSPSIs1280x576Baseline31() throws {
        // LinkFakeFrameSource.sps / TestFrameSource.sps (decoded by hand: 80×36 MBs, no cropping).
        let sps = Data([0x67, 0x42, 0x00, 0x1F, 0xDA, 0x01, 0x40, 0x12, 0x69, 0xA8])
        let info = try XCTUnwrap(H264SPS.parse(nal: sps))
        // Constraint byte 0x00, frame_num 4 bits, POC type 2, 1 reference; the VUI (video signal type,
        // colour description) is cut off after 3 bits of colour_primaries: kept, reorder unknown.
        XCTAssertEqual(info, H264SPSInfo(profileIdc: 66, levelIdc: 31, width: 1280, height: 576, seqParameterSetId: 0,
                                         constraintFlags: 0x00, log2MaxFrameNum: 4, pocType: 2, maxNumRefFrames: 1,
                                         frameMbsOnly: true, frameCropping: false, vuiPresent: true,
                                         maxNumReorderFrames: nil, maxDecFrameBuffering: nil))
        let au = AnnexB.join([sps, Data([0x68, 0xCE, 0x0D, 0x88]), Data([0x65, 0x88, 0x84, 0x01])])
        XCTAssertEqual(H264SPS.parse(accessUnit: au), info)
    }

    func testDashCanvasesRoundTrip() {
        for (w, h) in [(800, 384), (800, 944), (1280, 576), (544, 512), (1024, 592)] {
            let nal = SPSBuilder.baseline(widthMbs: w / 16, heightMapUnits: h / 16)
            let info = H264SPS.parse(nal: nal)
            XCTAssertEqual(info?.width, w, "\(w)x\(h)")
            XCTAssertEqual(info?.height, h, "\(w)x\(h)")
            XCTAssertEqual(info?.profileIdc, 66)
        }
        // Main profile, poc types 0 and 1.
        XCTAssertEqual(H264SPS.parse(nal: SPSBuilder.baseline(profile: 77, widthMbs: 50, heightMapUnits: 59, pocType: 0))?.height, 944)
        XCTAssertEqual(H264SPS.parse(nal: SPSBuilder.baseline(widthMbs: 50, heightMapUnits: 24, pocType: 1))?.width, 800)
    }

    func testCroppingAndFieldCoding() {
        // 1920×1080: 120×68 MBs coded (1088 lines), crop_bottom 4 × CropUnitY 2 = 8 lines.
        let hd = SPSBuilder.baseline(widthMbs: 120, heightMapUnits: 68, crop: (0, 0, 0, 4))
        XCTAssertEqual(H264SPS.parse(nal: hd).map { [$0.width, $0.height] }, [1920, 1080])
        // Left/right cropping uses CropUnitX 2 for 4:2:0.
        let narrow = SPSBuilder.baseline(widthMbs: 50, heightMapUnits: 24, crop: (1, 2, 0, 0))
        XCTAssertEqual(H264SPS.parse(nal: narrow)?.width, 800 - 2 * 3)
        // Field coding: frame height = 2 × map units × 16.
        let interlaced = SPSBuilder.baseline(widthMbs: 45, heightMapUnits: 18, frameMbsOnly: false)
        XCTAssertEqual(H264SPS.parse(nal: interlaced).map { [$0.width, $0.height] }, [720, 576])
    }

    func testHighProfileWithScalingMatrix() {
        var s = SPSBuilder()
        s.u(8, 100); s.u(8, 0); s.u(8, 40)
        s.ue(0)
        s.ue(1)          // chroma_format_idc 4:2:0
        s.ue(0); s.ue(0) // bit depths
        s.u(1, 0)        // qpprime_y_zero_transform_bypass_flag
        s.u(1, 1)        // seq_scaling_matrix_present_flag
        for i in 0 ..< 8 {
            if i == 1 || i == 6 {
                s.u(1, 1)
                for j in 0 ..< (i < 6 ? 16 : 64) { s.se(j == 0 ? 8 : (j % 3 == 0 ? -2 : 1)) }
            } else {
                s.u(1, 0)
            }
        }
        s.ue(4)          // log2_max_frame_num_minus4
        s.ue(0); s.ue(4) // poc type 0, log2_max_poc_lsb_minus4
        s.ue(4); s.u(1, 0)
        s.ue(79); s.ue(44); s.u(1, 1); s.u(1, 1); s.u(1, 0); s.u(1, 0)
        let info = H264SPS.parse(nal: s.nal())
        XCTAssertEqual(info, H264SPSInfo(profileIdc: 100, levelIdc: 40, width: 1280, height: 720, seqParameterSetId: 0,
                                         constraintFlags: 0, log2MaxFrameNum: 8, pocType: 0, maxNumRefFrames: 4,
                                         frameMbsOnly: true, frameCropping: false, vuiPresent: false,
                                         maxNumReorderFrames: nil, maxDecFrameBuffering: nil))
    }

    func testEmulationPreventionIsRemoved() {
        // constraint 0x00 + level 0x00 make "42 00 00"; a long Exp-Golomb code (id 63 → six leading
        // zero bits) makes the next byte 0x02, so the encoder must insert an 0x03.
        let nal = SPSBuilder.baseline(constraints: 0, level: 0, spsId: 63, widthMbs: 1, heightMapUnits: 1)
        XCTAssertTrue(nal.count > 5 && [UInt8](nal)[1 ... 4] == [0x42, 0x00, 0x00, 0x03], [UInt8](nal).map { String($0, radix: 16) }.joined(separator: " "))
        XCTAssertEqual(H264SPS.parse(nal: nal).map { [$0.width, $0.height] }, [16, 16])
        XCTAssertEqual(H264SPS.removeEmulationPrevention([0, 0, 3, 1, 0, 0, 3, 0, 0, 3]), [0, 0, 1, 0, 0, 0, 0])
    }

    func testMalformedInputYieldsNil() {
        let good = SPSBuilder.baseline(widthMbs: 50, heightMapUnits: 24)
        for n in 0 ..< good.count - 1 where n < 6 || n > good.count - 3 {
            XCTAssertNil(H264SPS.parse(nal: good.prefix(n)), "truncated to \(n) bytes")
        }
        XCTAssertNil(H264SPS.parse(nal: Data([0x68, 0xCE, 0x0D, 0x88])), "a PPS is not an SPS")
        XCTAssertNil(H264SPS.parse(nal: Data([0x67, 0x42, 0x00, 0x00])), "the relay tests' synthetic SPS")
        XCTAssertNil(H264SPS.parse(nal: Data([0x67, 0x42, 0, 31] + [UInt8](repeating: 0, count: 40))), "runaway Exp-Golomb")
        XCTAssertNil(H264SPS.parse(accessUnit: AnnexB.join([Data([0x65, 0x88])])), "no SPS in the AU")
        XCTAssertNil(H264SPS.parse(accessUnit: Data()))
    }

    // MARK: - Locked iPhone, Phase 0 (P0-1): every SPS field, the VUI, the PPS
    // Expected values decoded field by field with lock/encoders/tools/spsdump.py (the design's vectors).

    func testVideoToolboxSimulatorSPSAllFields() throws {
        // 0xE0, level 31, frame_num 5 bits, POC 0, 2 refs, 800×384; its VUI has a NAL HRD and no
        // bitstream_restriction, so reorder / buffering are unknown.
        let info = try XCTUnwrap(H264SPS.parse(nal: H264Fixture.vtSPS))
        XCTAssertEqual(info, H264SPSInfo(profileIdc: 66, levelIdc: 31, width: 800, height: 384, seqParameterSetId: 0,
                                         constraintFlags: 0xE0, log2MaxFrameNum: 5, pocType: 0, maxNumRefFrames: 2,
                                         frameMbsOnly: true, frameCropping: false, vuiPresent: true,
                                         maxNumReorderFrames: nil, maxDecFrameBuffering: nil))
        XCTAssertEqual(info.summary, "profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=-")
        XCTAssertEqual(H264SPS.parse(accessUnit: H264Fixture.validIDR), info)
    }

    func testReferenceSPSAllFields() throws {
        // 0xC0, frame_num 4 bits, POC 2, 1 ref; VUI with only bitstream_restriction: reorder 0, buffering 1.
        let info = try XCTUnwrap(H264SPS.parse(nal: H264Fixture.referenceSPS))
        XCTAssertEqual(info, H264SPSInfo(profileIdc: 66, levelIdc: 31, width: 800, height: 384, seqParameterSetId: 0,
                                         constraintFlags: 0xC0, log2MaxFrameNum: 4, pocType: 2, maxNumRefFrames: 1,
                                         frameMbsOnly: true, frameCropping: false, vuiPresent: true,
                                         maxNumReorderFrames: 0, maxDecFrameBuffering: 1))
        XCTAssertEqual(info.summary, "profile 66 constraints 0xC0 level 31 800x384 poc 2 refs 1 frame_num_bits 4 vui=yes reorder=0")
    }

    func testTruncatedVUIVectorKeeps1280x576() throws {
        // The repo's fake-source SPS stops 3 bits into colour_primaries: the SPS stays, reorder unknown.
        let info = try XCTUnwrap(H264SPS.parse(nal: H264Fixture.wrongSizeSPS))
        XCTAssertEqual([info.width, info.height], [1280, 576])
        XCTAssertTrue(info.vuiPresent)
        XCTAssertNil(info.maxNumReorderFrames)
        XCTAssertNil(info.maxDecFrameBuffering)
        XCTAssertEqual(info.summary, "profile 66 constraints 0x00 level 31 1280x576 poc 2 refs 1 frame_num_bits 4 vui=yes reorder=-")
        // The mirror relay test vectors (no VUI) keep their sizes and read as "no VUI".
        let relay800x384 = Data([0x67, 0x42, 0xC0, 0x1F, 0xDA, 0x03, 0x20, 0xC6, 0x40])
        XCTAssertEqual(H264SPS.parse(nal: relay800x384),
                       H264SPSInfo(profileIdc: 66, levelIdc: 31, width: 800, height: 384, constraintFlags: 0xC0,
                                   log2MaxFrameNum: 4, pocType: 2, maxNumRefFrames: 1))
    }

    func testFixtureBuildersReproduceTheRealVectors() {
        // So every synthetic fault below differs from a real, dash-proven stream in exactly one field.
        XCTAssertEqual(H264Fixture.SPS().nal(), H264Fixture.vtSPS)
        XCTAssertEqual(H264Fixture.SPS.reference.nal(), H264Fixture.referenceSPS)
        XCTAssertEqual(H264Fixture.PPS().nal(), H264Fixture.vtPPS)
        XCTAssertEqual([UInt8](H264Fixture.slice(idr: true, sliceType: 7).prefix(2)), [0x65, 0x88])
        XCTAssertEqual([UInt8](H264Fixture.slice(idr: false, sliceType: 5).prefix(2)), [0x41, 0x9A])
    }

    func testEveryNewSPSFieldIsRead() throws {
        let sps = H264Fixture.SPS(header: 0x67, profile: 77, constraints: 0x40, level: 40, spsId: 5, log2MaxFrameNumMinus4: 12,
                                  pocType: 1, maxNumRefFrames: 16, gapsInFrameNumAllowed: true, widthMbs: 80, heightMapUnits: 23,
                                  frameMbsOnly: false, crop: (0, 0, 0, 2), vui: nil)
        let info = try XCTUnwrap(H264SPS.parse(nal: sps.nal()))
        // Field coding: 2 × 23 × 16 = 736 lines, minus 2 × 2 × 2 cropped = 728.
        XCTAssertEqual(info, H264SPSInfo(profileIdc: 77, levelIdc: 40, width: 1280, height: 728, seqParameterSetId: 5,
                                         constraintFlags: 0x40, log2MaxFrameNum: 16, pocType: 1, maxNumRefFrames: 16,
                                         frameMbsOnly: false, frameCropping: true, vuiPresent: false,
                                         maxNumReorderFrames: nil, maxDecFrameBuffering: nil))
        XCTAssertEqual(info.summary, "profile 77 constraints 0x40 level 40 1280x728 poc 1 refs 16 frame_num_bits 16 vui=no reorder=-")
        // The older tests' builder: sps id 63, constraint byte 0 (always two hex digits).
        let old = try XCTUnwrap(H264SPS.parse(nal: SPSBuilder.baseline(constraints: 0, level: 0, spsId: 63, widthMbs: 1, heightMapUnits: 1)))
        XCTAssertEqual(old.seqParameterSetId, 63)
        XCTAssertEqual(old.summary, "profile 66 constraints 0x00 level 0 16x16 poc 2 refs 1 frame_num_bits 4 vui=no reorder=-")
    }

    func testEveryVUIPartIsSkippedExactly() throws {
        // Every optional VUI part present (Extended_SAR, overscan, video signal with colour, chroma location,
        // timing, a NAL HRD with 2 and a VCL HRD with 3 CPB specifications, low delay, pic_struct), then
        // bitstream_restriction: misreading any part would shift the two values read last.
        let vui = H264Fixture.VUI(aspectRatioIdc: 255, sar: (64, 45), overscanAppropriate: true,
                                  videoSignal: .init(format: 2, fullRange: true, colour: (1, 1, 1)), chromaLocation: (2, 3),
                                  timing: (1001, 60000, true), nalHRD: .init(cpbCountMinus1: 1, bitRateValueMinus1: 5000),
                                  vclHRD: .init(cpbCountMinus1: 2, cbr: true), lowDelayHRD: true, picStructPresent: true,
                                  restriction: .init(maxBytesPerPicDenom: 2, maxBitsPerMbDenom: 1, log2MaxMvLengthHorizontal: 9,
                                                     log2MaxMvLengthVertical: 8, maxNumReorderFrames: 2, maxDecFrameBuffering: 3))
        let info = try XCTUnwrap(H264SPS.parse(nal: H264Fixture.SPS(vui: vui).nal()))
        XCTAssertTrue(info.vuiPresent)
        XCTAssertEqual(info.maxNumReorderFrames, 2)
        XCTAssertEqual(info.maxDecFrameBuffering, 3)
        XCTAssertEqual([info.width, info.height, info.maxNumRefFrames], [800, 384, 2])
        XCTAssertEqual(info.summary, "profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=2")
        // An aspect ratio other than Extended_SAR has no sar_width / sar_height.
        let plain = H264Fixture.VUI(aspectRatioIdc: 1, restriction: .init(maxNumReorderFrames: 1, maxDecFrameBuffering: 4))
        XCTAssertEqual(H264SPS.parse(nal: H264Fixture.SPS(vui: plain).nal())?.maxDecFrameBuffering, 4)
    }

    func testVUIWithoutBitstreamRestrictionHasNoReorder() throws {
        for vui in [H264Fixture.VUI(), H264Fixture.VUI(timing: (1, 50, false)), H264Fixture.VUI(vclHRD: .init()),
                    H264Fixture.VUI.videoToolbox] {
            let info = try XCTUnwrap(H264SPS.parse(nal: H264Fixture.SPS(vui: vui).nal()))
            XCTAssertTrue(info.vuiPresent)
            XCTAssertNil(info.maxNumReorderFrames)
            XCTAssertNil(info.maxDecFrameBuffering)
        }
    }

    func testVUICutAtEveryBitKeepsTheSPS() throws {
        // A full VUI cut after every bit from vui_parameters_present_flag on (zero padding to the byte):
        // the SPS and its size always survive, and reorder / buffering are either unknown or exact —
        // never a value made up from missing bits.
        let sps = H264Fixture.SPS(vui: H264Fixture.VUI(aspectRatioIdc: 255, videoSignal: .init(), timing: (1, 30, true),
                                                         nalHRD: .init(cpbCountMinus1: 1),
                                                         restriction: .init(maxNumReorderFrames: 2, maxDecFrameBuffering: 3)))
        var head = H264BitWriter()
        sps.writeHead(&head)
        var full = head
        full.flag(true)
        sps.vui?.write(&full)
        var complete = 0
        for cut in head.bits.count ... full.bits.count {
            var w = H264BitWriter()
            for bit in full.bits.prefix(cut) { w.u(1, Int(bit)) }
            let info = try XCTUnwrap(H264SPS.parse(nal: w.nal(header: 0x27, trailing: false)), "cut after \(cut) bits")
            XCTAssertEqual([info.width, info.height, info.maxNumRefFrames, info.log2MaxFrameNum], [800, 384, 2, 5], "cut \(cut)")
            XCTAssertEqual(info.vuiPresent, cut > head.bits.count, "cut \(cut)")
            if cut <= full.bits.count - 8 { XCTAssertNil(info.maxNumReorderFrames, "cut \(cut)") }
            if let reorder = info.maxNumReorderFrames {
                XCTAssertEqual(reorder, 2, "cut \(cut)")
                XCTAssertEqual(info.maxDecFrameBuffering, 3, "cut \(cut)")
                complete += 1
            } else {
                XCTAssertNil(info.maxDecFrameBuffering, "cut \(cut)")
            }
        }
        XCTAssertGreaterThanOrEqual(complete, 1, "the uncut SPS reads its bitstream_restriction")
    }

    func testSPSEndingBeforeTheVUIFlagKeepsItsSize() throws {
        // Before the VUI was read, an SPS that stops right after the frame cropping gave its size; it
        // still does (the mirror host's canvas check depends on it), as "no VUI".
        let sps = H264Fixture.SPS(header: 0x67, constraints: 0xC0, log2MaxFrameNumMinus4: 1, pocType: 2, maxNumRefFrames: 15)
        var w = H264BitWriter()
        sps.writeHead(&w)
        XCTAssertEqual(w.bits.count, 64, "byte-aligned, so nothing follows the cropping flag")
        let info = try XCTUnwrap(H264SPS.parse(nal: w.nal(header: 0x67, trailing: false)))
        XCTAssertEqual(info, H264SPSInfo(profileIdc: 66, levelIdc: 31, width: 800, height: 384, constraintFlags: 0xC0,
                                         log2MaxFrameNum: 5, pocType: 2, maxNumRefFrames: 15))
    }

    func testMalformedHRDKeepsTheSPSWithoutReorder() throws {
        // 33 CPB specifications do not exist (cpb_cnt_minus1 ≤ 31): the VUI is unreadable from there on.
        let bad = H264Fixture.VUI(nalHRD: .init(cpbCountMinus1: 32), restriction: .init(maxNumReorderFrames: 0, maxDecFrameBuffering: 2))
        let info = try XCTUnwrap(H264SPS.parse(nal: H264Fixture.SPS(vui: bad).nal()))
        XCTAssertTrue(info.vuiPresent)
        XCTAssertNil(info.maxNumReorderFrames)
        XCTAssertEqual([info.width, info.height], [800, 384])
        // 32 (cpb_cnt_minus1 31) is the maximum and reads.
        let most = H264Fixture.VUI(vclHRD: .init(cpbCountMinus1: 31), restriction: .init(maxNumReorderFrames: 0, maxDecFrameBuffering: 2))
        XCTAssertEqual(H264SPS.parse(nal: H264Fixture.SPS(vui: most).nal())?.maxDecFrameBuffering, 2)
    }

    func testVideoToolboxPPSAllFields() throws {
        // CAVLC, deblocking control 1, pic_init_qp 28, bottom-field POC present 1.
        let pps = try XCTUnwrap(H264PPS.parse(nal: H264Fixture.vtPPS))
        XCTAssertEqual(pps, H264PPSInfo(picParameterSetId: 0, seqParameterSetId: 0, entropyCodingCABAC: false,
                                        bottomFieldPicOrderInFramePresent: true, numSliceGroups: 1, numRefIdxL0DefaultActive: 1,
                                        weightedPred: false, weightedBipredIdc: 0, picInitQp: 28,
                                        deblockingFilterControlPresent: true, constrainedIntraPred: false,
                                        redundantPicCntPresent: false))
        XCTAssertEqual(pps.summary, "pps cavlc deblock_ctrl=1 qp=28")
        // The Android-style fake-source PPS: qp 29, no deblocking control.
        let fake = try XCTUnwrap(H264PPS.parse(nal: H264Fixture.fakeSourcePPS))
        XCTAssertEqual(fake, H264PPSInfo(picInitQp: 29))
        XCTAssertEqual(fake.summary, "pps cavlc deblock_ctrl=0 qp=29")
        XCTAssertEqual(H264PPS.parse(accessUnit: H264Fixture.validIDR), pps)
        XCTAssertNil(H264PPS.parse(accessUnit: AnnexB.join([H264Fixture.vtSPS, H264Fixture.idrSlice])), "no PPS in the AU")
        XCTAssertNil(H264PPS.parse(accessUnit: Data()))
    }

    func testEveryPPSFieldIsRead() throws {
        let nal = H264Fixture.PPS(ppsId: 3, spsId: 1, cabac: true, bottomFieldPicOrderInFramePresent: false, l0Minus1: 2,
                                  l1Minus1: 1, weightedPred: true, weightedBipredIdc: 2, qpMinus26: -6, qsMinus26: 3,
                                  chromaQpIndexOffset: -2, deblockingFilterControl: false, constrainedIntraPred: true,
                                  redundantPicCnt: true).nal()
        let pps = try XCTUnwrap(H264PPS.parse(nal: nal))
        XCTAssertEqual(pps, H264PPSInfo(picParameterSetId: 3, seqParameterSetId: 1, entropyCodingCABAC: true,
                                        bottomFieldPicOrderInFramePresent: false, numSliceGroups: 1, numRefIdxL0DefaultActive: 3,
                                        weightedPred: true, weightedBipredIdc: 2, picInitQp: 20,
                                        deblockingFilterControlPresent: false, constrainedIntraPred: true,
                                        redundantPicCntPresent: true))
        XCTAssertEqual(pps.summary, "pps cabac deblock_ctrl=0 qp=20")
    }

    func testPPSSliceGroupMapsAreSkipped() {
        for mapType in 0 ... 6 {
            for groupsMinus1 in [1, 2, 7] {
                let nal = H264Fixture.PPS(sliceGroupsMinus1: groupsMinus1, sliceGroupMapType: mapType, mapUnitsMinus1: 299).nal()
                let pps = H264PPS.parse(nal: nal)
                XCTAssertEqual(pps?.numSliceGroups, groupsMinus1 + 1, "map type \(mapType), \(groupsMinus1 + 1) groups")
                // The fields after the map are read in place.
                XCTAssertEqual(pps?.picInitQp, 28, "map type \(mapType)")
                XCTAssertEqual(pps?.deblockingFilterControlPresent, true, "map type \(mapType)")
            }
        }
        XCTAssertNil(H264PPS.parse(nal: H264Fixture.PPS(sliceGroupsMinus1: 1, sliceGroupMapType: 7).nal()), "unknown map type")
        XCTAssertNil(H264PPS.parse(nal: H264Fixture.PPS(sliceGroupsMinus1: 8).nal()), "more than 8 slice groups")
        XCTAssertNil(H264PPS.parse(nal: H264Fixture.PPS(sliceGroupsMinus1: 1, sliceGroupMapType: 6, mapUnitsMinus1: 139_264).nal()),
                     "an explicit map larger than any level")
    }

    func testMalformedPPSYieldsNil() {
        for n in 0 ..< H264Fixture.vtPPS.count {
            XCTAssertNil(H264PPS.parse(nal: H264Fixture.vtPPS.prefix(n)), "truncated to \(n) bytes")
        }
        XCTAssertNil(H264PPS.parse(nal: H264Fixture.vtSPS), "an SPS is not a PPS")
        XCTAssertNil(H264PPS.parse(nal: Data([0x28] + [UInt8](repeating: 0, count: 12))), "runaway Exp-Golomb")
    }

    func testPPSEmulationPreventionIsRemoved() {
        // A pic_parameter_set_id of 2^22 (out of range, but readable) starts with 22 zero bits, so the
        // RBSP begins 00 00 02 and the builder inserts an emulation-prevention 0x03.
        let nal = H264Fixture.PPS(ppsId: 1 << 22).nal()
        XCTAssertEqual([UInt8](nal)[1 ... 4], [0x00, 0x00, 0x03, 0x02])
        XCTAssertEqual(H264PPS.parse(nal: nal)?.picParameterSetId, 1 << 22)
        XCTAssertEqual(H264PPS.parse(nal: nal)?.picInitQp, 28)
    }
}
