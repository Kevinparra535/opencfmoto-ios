// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0: the platform-neutral part of the encoder seam (DashVideoEncoder.swift) and
// the VideoToolbox status names of the `[bg]` lines. Runs on Linux.
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class VideoDashEncoderTests: XCTestCase {
    func testEncoderKindNamesAndRungs() {
        XCTAssertEqual(DashEncoderKind.videoToolboxHardware.description, "vt-hw")
        XCTAssertEqual(DashEncoderKind.videoToolboxSoftware.description, "vt-sw")
        XCTAssertEqual(DashEncoderKind.cpu(backend: "minih264").description, "cpu-minih264")
        XCTAssertEqual(DashEncoderKind.cpu(backend: "").description, "cpu")
        XCTAssertNil(DashEncoderKind.videoToolboxHardware.backgroundRung)
        XCTAssertEqual(DashEncoderKind.videoToolboxSoftware.backgroundRung, .videoToolboxSoftware)
        XCTAssertEqual(DashEncoderKind.cpu(backend: "openh264").backgroundRung, .cpu)
        XCTAssertNotEqual(DashEncoderKind.cpu(backend: "a"), DashEncoderKind.cpu(backend: "b"))
    }

    func testFailureDescriptionIsTheMessage() {
        let f = DashEncoderFailure(status: -12903, requiresRecreation: true, message: "VT output error: kVTInvalidSessionErr")
        XCTAssertEqual(f.description, "VT output error: kVTInvalidSessionErr")
        XCTAssertEqual("\(f)", "VT output error: kVTInvalidSessionErr")
        let plain = DashEncoderFailure(message: "x")
        XCTAssertNil(plain.status)
        XCTAssertFalse(plain.requiresRecreation)
    }

    /// `onFailure` gets the status, whether the session must be re-created, and the error text.
    func testEncoderFailureFromAStatus() {
        XCTAssertEqual(H264EncoderStatus.failure(status: -12903, message: "m"),
                       DashEncoderFailure(status: -12903, requiresRecreation: true, message: "m"))
        XCTAssertEqual(H264EncoderStatus.failure(status: -12915, message: "m").requiresRecreation, true)
        XCTAssertEqual(H264EncoderStatus.failure(status: -12902, message: "m").requiresRecreation, false)
        XCTAssertEqual(H264EncoderStatus.failure(status: nil, message: "m"),
                       DashEncoderFailure(status: nil, requiresRecreation: false, message: "m"))
    }

    /// `create=` texts: the constant name for the statuses the encoder knows, `OSStatus(<code>)` else.
    func testKnownStatusNamesForTheCreateField() {
        XCTAssertEqual(H264EncoderStatus.knownName(-12908), "kVTCouldNotFindVideoEncoderErr")
        XCTAssertEqual(H264EncoderStatus.knownName(-12915), "kVTVideoEncoderNotAvailableNowErr")
        XCTAssertEqual(H264EncoderStatus.knownName(-12903), "kVTInvalidSessionErr")
        XCTAssertEqual(H264EncoderStatus.knownName(-12902), "kVTParameterErr")
        XCTAssertEqual(H264EncoderStatus.knownName(0), "noErr")
        XCTAssertNil(H264EncoderStatus.knownName(-1))
        XCTAssertEqual(BackgroundLog.osStatus(-12908, name: H264EncoderStatus.knownName(-12908)),
                       "kVTCouldNotFindVideoEncoderErr(-12908)")
        XCTAssertEqual(BackgroundLog.osStatus(-1, name: H264EncoderStatus.knownName(-1)), "OSStatus(-1)")
        XCTAssertEqual(BackgroundLog.osStatus(0, name: H264EncoderStatus.knownName(0)), "noErr")
        // `describe` (the existing log texts) is unchanged.
        XCTAssertEqual(H264EncoderStatus.describe(-12908), "kVTCouldNotFindVideoEncoderErr")
        XCTAssertEqual(H264EncoderStatus.describe(0), "noErr")
        XCTAssertEqual(H264EncoderStatus.describe(-1), "OSStatus -1")
    }
}
