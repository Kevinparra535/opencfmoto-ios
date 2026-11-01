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
        XCTAssertEqual(info, H264SPSInfo(profileIdc: 66, levelIdc: 31, width: 1280, height: 576))
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
        XCTAssertEqual(info, H264SPSInfo(profileIdc: 100, levelIdc: 40, width: 1280, height: 720))
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
}
