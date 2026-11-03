// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0: the exact text of the video diagnostics lines L1–L13 (BackgroundLog; the
// contract's section 7 forms), the hold reasons, the stream issue codes, BatteryStatus and the
// encoder tag of EncodedFrame.
import XCTest
@testable import OpenCfMotoCore

final class BackgroundLogTests: XCTestCase {
    private typealias L = BackgroundLog

    // MARK: Field values

    func testDuration() {
        let cases: [(Double, String)] = [
            (0, "0s"), (0.4, "0s"), (0.5, "1s"), (45, "45s"), (59.4, "59s"), (59.6, "1m00s"), (60, "1m00s"), (723, "12m03s"),
            (3599.4, "59m59s"), (3600, "1h00m00s"), (3723, "1h02m03s"), (36_000, "10h00m00s"),
            (-3, "0s"), (.nan, "0s"), (.infinity, "0s"), (-.infinity, "0s"),
        ]
        for (seconds, text) in cases { XCTAssertEqual(L.duration(seconds), text, "\(seconds)") }
        XCTAssertEqual(L.duration(1e300), "277777h46m40s", "capped at 1e9 s, no trap")
    }

    func testFieldHelpers() {
        XCTAssertEqual([L.hardware(true), L.hardware(false), L.hardware(nil)], ["true", "false", "?"])
        XCTAssertEqual(L.probe(.keyframe(bytes: 20112, ms: 45.4)), "IDR 20112b in 45ms")
        XCTAssertEqual(L.probe(.keyframe(bytes: 9, ms: .nan)), "IDR 9b in ?ms")
        XCTAssertEqual(L.probe(.nothing(waitedMs: 500)), "none in 500ms")
        XCTAssertEqual(L.probe(.failed(code: -12903)), "failed -12903")
        XCTAssertEqual(L.probe(.failed(code: nil)), "failed")
        XCTAssertEqual(L.probe(nil), "-")
        XCTAssertEqual(L.streamCheck(nil), "-")
        XCTAssertEqual(L.streamCheck([]), "ok")
        XCTAssertEqual(L.streamCheck([.size(width: 1280, height: 576), .level(22)]), "size-1280x576,level-22")
        XCTAssertEqual(L.verdict(.accept), "accepted")
        XCTAssertEqual(L.verdict(.reject("hw=true")), "rejected: hw=true")
        XCTAssertEqual(L.rungName(.videoToolboxSoftware, cpuBackend: "minih264"), "vt-sw")
        XCTAssertEqual(L.rungName(.hold, cpuBackend: "minih264"), "hold")
        XCTAssertEqual(L.rungName(.cpu, cpuBackend: "minih264"), "cpu-minih264")
        XCTAssertEqual(L.rungName(.cpu, cpuBackend: nil), "cpu")
        XCTAssertEqual(L.rungName(.cpu, cpuBackend: ""), "cpu")
        XCTAssertEqual(L.osStatus(0, name: "x"), "noErr")
        XCTAssertEqual(L.osStatus(-12908, name: "kVTCouldNotFindVideoEncoderErr"), "kVTCouldNotFindVideoEncoderErr(-12908)")
        XCTAssertEqual(L.osStatus(-1, name: nil), "OSStatus(-1)")
        XCTAssertEqual(L.osStatus(-1, name: ""), "OSStatus(-1)")
        XCTAssertEqual([L.SoftwareSession.preWarmed, .fresh, .encoderID("com.apple.videotoolbox.videoencoder.h264")].map(\.text),
                       ["pre-warmed", "fresh", "id=com.apple.videotoolbox.videoencoder.h264"])
    }

    // MARK: L1–L3

    func testL1FirstIDRWithTheFullParameterSets() {
        // The contract's exact L1 line, now with the parsed SPS and PPS.
        XCTAssertEqual(L.firstIDR(label: "own", bytes: 23410, sps: H264Fixture.vtSPS, pps: H264Fixture.vtPPS),
                       "[own] first IDR 23410b SPS 27 42 e0 1f a9 18 19 06 36 02 d4 08 08 08 c2 b5 ef 7c 04 PPS 28 de 09 c8 \u{2014} "
                           + "profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=- | "
                           + "pps cavlc deblock_ctrl=1 qp=28")
        XCTAssertEqual(L.firstIDR(label: "hold", bytes: 9123, sps: H264Fixture.referenceSPS, pps: H264Fixture.fakeSourcePPS),
                       "[hold] first IDR 9123b SPS 67 42 c0 1f da 03 20 c6 80 78 44 23 50 PPS 68 ce 0d 88 \u{2014} "
                           + "profile 66 constraints 0xC0 level 31 800x384 poc 2 refs 1 frame_num_bits 4 vui=yes reorder=0 | "
                           + "pps cavlc deblock_ctrl=0 qp=29")
        XCTAssertEqual(L.firstIDR(label: "x", bytes: 1, sps: nil, pps: nil), "[x] first IDR 1b SPS - PPS - \u{2014} sps ? | pps ?")
        XCTAssertEqual(L.firstIDR(label: "mirror", bytes: 2, sps: Data([0x67, 0x42]), pps: Data([0x28])),
                       "[mirror] first IDR 2b SPS 67 42 PPS 28 \u{2014} sps ? | pps ?", "unreadable parameter sets")
        // Long parameter sets are never cut.
        let long = H264Fixture.SPS(vui: H264Fixture.VUI(aspectRatioIdc: 255, timing: (1001, 60000, true),
                                                          nalHRD: .init(cpbCountMinus1: 15, bitRateValueMinus1: 70000),
                                                          restriction: .init())).nal()
        XCTAssertGreaterThan(long.count, 64, "longer than hexDump's default limit")
        XCTAssertTrue(L.firstIDR(label: "own", bytes: 3, sps: long, pps: nil).contains(long.hexDump(limit: Int.max) + " PPS -"))
        XCTAssertFalse(L.firstIDR(label: "own", bytes: 3, sps: long, pps: nil).contains("…"))
    }

    func testL2EncoderList() {
        XCTAssertEqual(L.encoderList([]), "[vt-list] avc1 encoders: none")
        XCTAssertEqual(L.encoderList([.init(id: "a", name: "A b", isHardwareAccelerated: true),
                                      .init(id: "c", name: "C", isHardwareAccelerated: false),
                                      .init(id: "d", name: "D", isHardwareAccelerated: nil)]),
                       "[vt-list] avc1 encoders: a name=A b hw=true; c name=C hw=false; d name=D hw=?")
    }

    func testL3PreWarm() {
        XCTAssertEqual(L.preWarm(create: "noErr", usesHardware: nil, probe: .keyframe(bytes: 20112, ms: 45)),
                       "[bg] pre-warm vt-sw at inactive: create=noErr hw=? probe=IDR 20112b in 45ms")
        XCTAssertEqual(L.preWarm(create: "noErr", usesHardware: false, probe: .nothing(waitedMs: 300)),
                       "[bg] pre-warm vt-sw at inactive: create=noErr hw=false probe=none in 300ms")
        XCTAssertEqual(L.preWarm(create: L.osStatus(-12908, name: "kVTCouldNotFindVideoEncoderErr"), usesHardware: nil, probe: nil),
                       "[bg] pre-warm vt-sw at inactive: create=kVTCouldNotFindVideoEncoderErr(-12908) hw=? probe=-")
    }

    // MARK: L4–L6

    func testL4Enter() {
        let canvas = VideoCanvas(width: 800, height: 384)
        XCTAssertEqual(L.enter(canvas: canvas, policy: .videoToolboxSoftwareOnly, rungs: [.videoToolboxSoftware, .hold], cpuBackend: nil,
                               lastLiveIDRBytes: 23410, holdIDRs: 2),
                       "[bg] enter: canvas 800x384 policy=vtsw rungs=vt-sw,hold last-live-idr=23410b hold-idrs=2")
        XCTAssertEqual(L.enter(canvas: canvas, policy: .automatic, rungs: [.videoToolboxSoftware, .cpu, .hold], cpuBackend: "minih264",
                               lastLiveIDRBytes: nil, holdIDRs: 0),
                       "[bg] enter: canvas 800x384 policy=auto rungs=vt-sw,cpu-minih264,hold last-live-idr=none hold-idrs=0")
        XCTAssertEqual(L.enter(canvas: VideoCanvas(width: 800, height: 944), policy: .holdOnly, rungs: [.hold], cpuBackend: nil,
                               lastLiveIDRBytes: 5, holdIDRs: 1),
                       "[bg] enter: canvas 800x944 policy=hold rungs=hold last-live-idr=5b hold-idrs=1")
    }

    func testL5Tries() {
        XCTAssertEqual(L.tryVideoToolbox(.fresh, create: "noErr", usesHardware: nil, probe: .keyframe(bytes: 20112, ms: 45), issues: [],
                                         verdict: .accept),
                       "[bg] try vt-sw (fresh): create=noErr hw=? probe=IDR 20112b in 45ms sps=ok \u{2192} accepted")
        XCTAssertEqual(L.tryVideoToolbox(.preWarmed, create: "noErr", usesHardware: true, probe: .keyframe(bytes: 9, ms: 1), issues: [],
                                         verdict: .reject("hw=true")),
                       "[bg] try vt-sw (pre-warmed): create=noErr hw=true probe=IDR 9b in 1ms sps=ok \u{2192} rejected: hw=true")
        XCTAssertEqual(L.tryVideoToolbox(.encoderID("com.x"), create: "noErr", usesHardware: false, probe: .nothing(waitedMs: 500),
                                         issues: nil, verdict: .reject("probe=none")),
                       "[bg] try vt-sw (id=com.x): create=noErr hw=false probe=none in 500ms sps=- \u{2192} rejected: probe=none")
        XCTAssertEqual(L.tryVideoToolbox(.fresh, create: "kVTCouldNotFindVideoEncoderErr(-12908)", usesHardware: nil, probe: nil,
                                         issues: nil, verdict: .reject("not created")),
                       "[bg] try vt-sw (fresh): create=kVTCouldNotFindVideoEncoderErr(-12908) hw=? probe=- sps=- \u{2192} rejected: not created")
        XCTAssertEqual(L.tryVideoToolbox(.fresh, create: "noErr", usesHardware: nil, probe: .keyframe(bytes: 30000, ms: 20),
                                         issues: [.size(width: 1280, height: 576)], verdict: .reject("sps: size-1280x576")),
                       "[bg] try vt-sw (fresh): create=noErr hw=? probe=IDR 30000b in 20ms sps=size-1280x576 \u{2192} rejected: sps: size-1280x576")
        XCTAssertEqual(L.tryCPU(encoder: "cpu-minih264", configure: "ok", probe: .keyframe(bytes: 19876, ms: 12), issues: [], verdict: .accept),
                       "[bg] try cpu-minih264: configure=ok probe=IDR 19876b in 12ms sps=ok \u{2192} accepted")
        XCTAssertEqual(L.tryCPU(encoder: "cpu", configure: "invalid size", probe: nil, issues: nil, verdict: .reject("not created")),
                       "[bg] try cpu: configure=invalid size probe=- sps=- \u{2192} rejected: not created")
    }

    func testL6Outcome() {
        XCTAssertEqual(L.backgroundSoftware(fps: 8, encoder: "vt-sw", bitrate: 3_375_000),
                       "background \u{2192} backgroundSoftware @8fps (encoder vt-sw, 3375kbps)")
        XCTAssertEqual(L.backgroundSoftware(fps: 5, encoder: "cpu-minih264", bitrate: 1_536_999),
                       "background \u{2192} backgroundSoftware @5fps (encoder cpu-minih264, 1536kbps)", "kbps truncated")
        let reasons: [(HoldCause, String)] = [
            (.policy, "policy hold"), (.noEncoderRung, "no encoder rung"), (.allRungsRejected, "all rungs rejected"),
            (.demoted, "demoted"), (.budget("thermal critical"), "budget: thermal critical"),
        ]
        for (cause, text) in reasons {
            XCTAssertEqual(cause.description, text)
            XCTAssertEqual(L.backgroundHold(holdIDRs: 2, cause: cause), "background \u{2192} hold (2 hold IDR(s); reason: \(text))")
        }
    }

    // MARK: L7, L8

    func testL7L8Switches() {
        XCTAssertEqual(L.switchStarted(from: "vt-hw", to: "vt-sw", dumpFrame: 133),
                       "[switch] vt-hw \u{2192} vt-sw: gate closed; next frame on the wire is an IDR (dump frame #133)")
        XCTAssertEqual(L.switchStarted(from: "vt-sw", to: "hold", dumpFrame: nil),
                       "[switch] vt-sw \u{2192} hold: gate closed; next frame on the wire is an IDR")
        XCTAssertEqual(L.switchFirstIDR(encoder: "vt-sw", bytes: 19876, secondsAfterSwitch: 0.214, dumpFrame: 133),
                       "[switch] first vt-sw IDR on the wire: 19876b, 0.21s after the switch (dump frame #133)")
        XCTAssertEqual(L.switchFirstIDR(encoder: "vt-hw", bytes: 5, secondsAfterSwitch: nil, dumpFrame: nil),
                       "[switch] first vt-hw IDR on the wire: 5b")
        XCTAssertEqual(L.switchFirstIDR(encoder: "hold", bytes: 7, secondsAfterSwitch: 1.005, dumpFrame: nil),
                       "[switch] first hold IDR on the wire: 7b, 1.00s after the switch")
    }

    // MARK: L9, L10

    func testL9Status() {
        let s = L.Status(backgroundSeconds: 60, mode: "backgroundSoftware", encoder: "vt-sw", fpsCap: 8, outputFPS: 5.2, pullRate: 5.1,
                         served: 312, holdServed: 0, fallbackServed: 2, unanswered: 0, encoderErrors: 0, renderMs: 6.1, encodeMs: 7.8,
                         cpuPercent: 14.2, thermal: .none, lowPowerMode: false, queued: 0)
        XCTAssertEqual(L.backgroundStatus(s),
                       "[bg] +1m00s mode=backgroundSoftware enc=vt-sw cap=8fps out=5.2fps pulls=5.1/s served=312 (hold 0, fallback 2, none 0) "
                           + "errs=0 render=6.1ms enc=7.8ms cpu=14% thermal=none lowPower=false q=0")
        var h = s
        h.mode = "hold"
        h.encoder = "hold"
        h.fpsCap = nil
        h.encodeMs = nil
        h.cpuPercent = nil
        h.thermal = .severe
        h.lowPowerMode = true
        h.backgroundSeconds = 723
        h.served = 600
        h.holdServed = 600
        h.queued = 1
        XCTAssertEqual(L.backgroundStatus(h),
                       "[bg] +12m03s mode=hold enc=hold cap=- out=5.2fps pulls=5.1/s served=600 (hold 600, fallback 2, none 0) "
                           + "errs=0 render=6.1ms enc=- cpu=? thermal=severe lowPower=true q=1")
        h.cpuPercent = .nan
        h.outputFPS = .infinity
        XCTAssertTrue(L.backgroundStatus(h).contains(" out=?fps "))
        XCTAssertTrue(L.backgroundStatus(h).contains(" cpu=? "))
    }

    func testL10DryRun() {
        XCTAssertEqual(L.dryRun(renderMs: 6.3, convertMs: 0.94, loadMs: 10.2, iterations: 480, cpuPercent: 13.4),
                       "[bg-probe] render=6.3ms convert=0.9ms load=10ms n=480 cpu=13%")
        XCTAssertEqual(L.dryRun(renderMs: 0, convertMs: 0, loadMs: 0, iterations: 0, cpuPercent: nil),
                       "[bg-probe] render=0.0ms convert=0.0ms load=0ms n=0 cpu=?")
        XCTAssertEqual(L.dryRunEnded(afterSeconds: 600), "[bg-probe] dry run ended after 10m00s")
        XCTAssertEqual(L.dryRunEnded(afterSeconds: 42.4), "[bg-probe] dry run ended after 42s")
    }

    // MARK: L11–L13

    func testL11Budget() {
        let inputs = BackgroundBudget.Inputs(now: 1, cpu15s: 27, thermal: .none, lowPowerMode: false,
                                             battery: BatteryStatus(level: 0.64, state: .unplugged))
        XCTAssertEqual(L.budget(.init(from: .fps(8), to: .fps(5), reason: "cpu 27% (15s)", inputs: inputs)),
                       "[bg-budget] fps cap 8\u{2192}5: cpu 27% (15s) thermal=none lowPower=false batt=64% unplugged")
        XCTAssertEqual(L.budget(.init(from: .fps(2), to: .hold, reason: "thermal critical", inputs: inputs)),
                       "[bg-budget] \u{2192} hold: thermal critical")
        XCTAssertEqual(L.budget(.init(from: .hold, to: .fps(8), reason: "clear", inputs: .init(now: 0))),
                       "[bg-budget] hold \u{2192} fps cap 8: clear thermal=none lowPower=false batt=-")
        XCTAssertEqual(L.budget(.init(from: .hold, to: .fps(2), reason: "clear",
                                      inputs: .init(now: 0, thermal: .moderate, lowPowerMode: true,
                                                    battery: BatteryStatus(level: 1, state: .full)))),
                       "[bg-budget] hold \u{2192} fps cap 2: clear thermal=moderate lowPower=true batt=100% full")
    }

    func testL12DemotionAndRetry() {
        XCTAssertEqual(L.demoted(encoder: "vt-sw", reason: "3 encode errors in 10s (last VT output error: kVTInvalidSessionErr)", next: "hold"),
                       "[bg] vt-sw demoted: 3 encode errors in 10s (last VT output error: kVTInvalidSessionErr) \u{2192} hold")
        XCTAssertEqual(L.retryLadder(after: .demoted, attempt: 1), "[bg] retry ladder (60s after the demotion, attempt 1/3)")
        XCTAssertEqual(L.retryLadder(after: .budget("x"), attempt: 2), "[bg] retry ladder (clear for 60s, attempt 2/3)")
        XCTAssertEqual(L.retryLadder(after: .allRungsRejected, attempt: 3), "[bg] retry ladder (all rungs rejected, attempt 3/3)")
    }

    func testL13Foreground() {
        XCTAssertEqual(L.foreground(backgroundSeconds: 723, encoders: [.init(name: "vt-sw", frames: 3412, keyframes: 812, errors: 0,
                                                                             averageEncodeMs: 8.1)], holdServed: 4),
                       "foreground \u{2192} hardware encoder, IDR forced (background 12m03s: vt-sw 3412 frames 812 IDR 0 errors enc 8.1ms; hold served 4)")
        XCTAssertEqual(L.foreground(backgroundSeconds: 723, encoders: [], holdServed: 600),
                       "foreground \u{2192} hardware encoder, IDR forced (background 12m03s: hold served 600)")
        XCTAssertEqual(L.foreground(backgroundSeconds: 95, encoders: [.init(name: "vt-sw", frames: 10, keyframes: 2, errors: 3, averageEncodeMs: nil),
                                                                      .init(name: "cpu-minih264", frames: 5, keyframes: 5, errors: 0,
                                                                            averageEncodeMs: 12.26)], holdServed: 0),
                       "foreground \u{2192} hardware encoder, IDR forced (background 1m35s: vt-sw 10 frames 2 IDR 3 errors enc -, "
                           + "cpu-minih264 5 frames 5 IDR 0 errors enc 12.3ms; hold served 0)")
        XCTAssertTrue(L.foreground(backgroundSeconds: 1, encoders: [], holdServed: 0).hasPrefix("foreground \u{2192} hardware encoder, IDR forced"),
                      "the prefix of today's line, which the field logs are read by")
    }

    func testNoLineCarriesARedactedKey() {
        // LogRedactor rewrites `sn=`, `key=`, `token=`, `pwd=`: the diagnostics lines must never contain them.
        let lines = [
            L.firstIDR(label: "own", bytes: 1, sps: H264Fixture.vtSPS, pps: H264Fixture.vtPPS),
            L.encoderList([.init(id: "a", name: "b", isHardwareAccelerated: nil)]),
            L.preWarm(create: "noErr", usesHardware: nil, probe: nil),
            L.enter(canvas: VideoCanvas(width: 800, height: 384), policy: .automatic, rungs: [.hold], cpuBackend: nil, lastLiveIDRBytes: nil,
                    holdIDRs: 0),
            L.tryVideoToolbox(.fresh, create: "noErr", usesHardware: nil, probe: nil, issues: nil, verdict: .accept),
            L.tryCPU(encoder: "cpu", configure: "ok", probe: nil, issues: nil, verdict: .accept),
            L.backgroundSoftware(fps: 8, encoder: "vt-sw", bitrate: 1),
            L.backgroundHold(holdIDRs: 1, cause: .policy),
            L.switchStarted(from: "a", to: "b", dumpFrame: 1),
            L.switchFirstIDR(encoder: "a", bytes: 1, secondsAfterSwitch: 1, dumpFrame: 1),
            L.dryRun(renderMs: 1, convertMs: 1, loadMs: 1, iterations: 1, cpuPercent: 1),
            L.dryRunEnded(afterSeconds: 1),
            L.demoted(encoder: "a", reason: "b", next: "c"),
            L.retryLadder(after: .demoted, attempt: 1),
            L.foreground(backgroundSeconds: 1, encoders: [], holdServed: 0),
        ]
        for line in lines {
            for key in ["sn=", "key=", "token=", "pwd="] { XCTAssertFalse(line.contains(key), line) }
        }
    }

    // MARK: Codes and values

    func testStreamIssueCodes() {
        let codes: [(H264StreamIssue, String)] = [
            (.emptyAccessUnit, "empty-au"), (.threeByteStartCode, "start-code-3"), (.nalType(6), "nal-6"), (.notIDR, "no-idr"),
            (.mixedSlices, "mixed-slices"), (.missingSPS, "no-sps"), (.missingPPS, "no-pps"), (.repeatedParameterSet, "repeated-ps"),
            (.badIDROrder, "idr-order"), (.parameterSetsWithoutIDR, "ps-without-idr"), (.spsUnparsable, "sps-unparsable"),
            (.ppsUnparsable, "pps-unparsable"), (.profile(77), "profile-77"), (.level(30), "level-30"),
            (.size(width: 1280, height: 576), "size-1280x576"), (.cropping, "cropping"), (.fieldCoding, "field-coding"),
            (.pocType(1), "poc-1"), (.referenceFrames(3), "refs-3"), (.reorder(1), "reorder-1"), (.spsID(1), "sps-id-1"),
            (.cabac, "cabac"), (.sliceGroups(2), "slice-groups-2"), (.ppsID(1), "pps-id-1"), (.ppsSPSID(1), "pps-sps-id-1"),
            (.sliceType(0), "slice-P"), (.sliceType(1), "slice-B"), (.sliceType(2), "slice-I"), (.sliceType(3), "slice-SP"),
            (.sliceType(4), "slice-SI"), (.sliceType(6), "slice-B"), (.sliceType(9), "slice-SI"), (.sliceType(-1), "slice--1"),
            (.sliceUnparsable, "slice-unparsable"),
        ]
        for (issue, code) in codes { XCTAssertEqual(issue.description, code) }
        // The raw slice_type is kept: slice-B from 1 and from 6 are different issues.
        XCTAssertNotEqual(H264StreamIssue.sliceType(1), .sliceType(6))
    }

    func testBatteryStatus() throws {
        XCTAssertEqual(BatteryStatus(level: 0.64, state: .unplugged).logText, "64% unplugged")
        XCTAssertEqual(BatteryStatus(level: 0.634, state: .charging).logText, "63% charging")
        XCTAssertEqual(BatteryStatus(level: 0.636, state: .charging).percent, 64, "rounded")
        XCTAssertEqual(BatteryStatus(level: 1, state: .full).logText, "100% full")
        XCTAssertEqual(BatteryStatus(level: 1.2, state: .full).level, 1, "clamped")
        XCTAssertEqual(BatteryStatus(level: 0, state: .unplugged).logText, "0% unplugged")
        for level in [nil, -1, -0.01, .nan, .infinity] as [Double?] {
            let b = BatteryStatus(level: level, state: .unknown)
            XCTAssertNil(b.level, "\(String(describing: level))")
            XCTAssertNil(b.percent)
            XCTAssertEqual(b.logText, "?% unknown")
        }
        XCTAssertEqual(BatteryStatus.State.allCases.map(\.rawValue), ["unknown", "unplugged", "charging", "full"])
        XCTAssertEqual(BatteryStatus.State.allCases.map { BatteryStatus(level: 0.5, state: $0).isOnExternalPower }, [false, false, true, true])
        let status = BatteryStatus(level: 0.25, state: .charging)
        XCTAssertEqual(try JSONDecoder().decode(BatteryStatus.self, from: JSONEncoder().encode(status)), status)
    }

    func testEncoderTagIsDiagnosticsOnly() {
        let au = H264Fixture.validIDR
        let plain = EncodedFrame(accessUnit: au, isKeyframe: true, presentationTime: 1, sequence: 2)
        XCTAssertEqual(plain.encoderTag, 0, "not stamped by default")
        let tagged = EncodedFrame(accessUnit: au, isKeyframe: true, presentationTime: 1, sequence: 2, encoderTag: 7)
        XCTAssertEqual(tagged.encoderTag, 7)
        // Never on the wire: the same bytes with any tag.
        XCTAssertEqual(tagged.wireBytes, plain.wireBytes)
        XCTAssertEqual(plain.wireBytes.count, 4 + au.count)
        // Part of the synthesized Equatable.
        XCTAssertNotEqual(tagged, plain)
        var restamped = plain
        restamped.encoderTag = 7
        XCTAssertEqual(restamped, tagged)
    }
}
