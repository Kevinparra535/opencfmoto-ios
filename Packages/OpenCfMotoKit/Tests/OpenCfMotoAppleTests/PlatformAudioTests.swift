// SPDX-License-Identifier: AGPL-3.0-or-later
// Voice language selection, the silent WAV loop, volume-step math and the handlebar event emitter
// (runs on Linux too).

import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class PlatformAudioTests: XCTestCase {
    // MARK: Voice language

    func testVoiceLanguageMapping() {
        typealias V = SpeechVoiceLanguage
        XCTAssertEqual(V.voiceLanguage(appLanguage: "es", preferredLanguages: ["es-CO", "en-US"]), "es-MX")
        XCTAssertEqual(V.voiceLanguage(appLanguage: "es", preferredLanguages: ["es-ES"]), "es-ES")
        XCTAssertEqual(V.voiceLanguage(appLanguage: "es", preferredLanguages: ["es"]), "es-ES")
        XCTAssertEqual(V.voiceLanguage(appLanguage: "es", preferredLanguages: []), "es-ES")
        XCTAssertEqual(V.voiceLanguage(appLanguage: "es-419", preferredLanguages: []), "es-MX")
        XCTAssertEqual(V.voiceLanguage(appLanguage: "es_CO", preferredLanguages: []), "es-MX")
        XCTAssertEqual(V.voiceLanguage(appLanguage: "es-Latn-AR", preferredLanguages: []), "es-MX")
        XCTAssertEqual(V.voiceLanguage(appLanguage: "es", preferredLanguages: ["en-US", "es-AR"]), "es-MX")
        XCTAssertEqual(V.voiceLanguage(appLanguage: "en", preferredLanguages: ["es-CO"]), "en-US")
        XCTAssertEqual(V.voiceLanguage(appLanguage: nil, preferredLanguages: ["es-MX"]), "es-MX")
        XCTAssertEqual(V.voiceLanguage(appLanguage: nil, preferredLanguages: ["fr-FR"]), "en-US")
        XCTAssertEqual(V.voiceLanguage(appLanguage: nil, preferredLanguages: []), "en-US")
        XCTAssertEqual(V.voiceLanguage(appLanguage: "ES", preferredLanguages: ["ES-es"]), "es-ES")
        XCTAssertEqual(V.rateFactor, 0.95)
    }

    func testLanguageTagHelpers() {
        XCTAssertEqual(SpeechVoiceLanguage.languageCode("es-CO"), "es")
        XCTAssertEqual(SpeechVoiceLanguage.languageCode("EN_us"), "en")
        XCTAssertEqual(SpeechVoiceLanguage.regionCode("es-co"), "CO")
        XCTAssertEqual(SpeechVoiceLanguage.regionCode("es-419"), "419")
        XCTAssertEqual(SpeechVoiceLanguage.regionCode("zh-Hant-TW"), "TW")
        XCTAssertNil(SpeechVoiceLanguage.regionCode("es"))
    }

    // MARK: Silent WAV

    func testSilentWAVHeaderAndPayload() throws {
        let wav = SilentWAV.make()
        XCTAssertEqual(wav.count, 44 + 16_000)
        var r = ByteReader(wav)
        XCTAssertEqual(String(decoding: try r.bytes(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(try r.u32le(), 36 + 16_000)
        XCTAssertEqual(String(decoding: try r.bytes(4), as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: try r.bytes(4), as: UTF8.self), "fmt ")
        XCTAssertEqual(try r.u32le(), 16)
        XCTAssertEqual(try r.u16le(), 1, "PCM")
        XCTAssertEqual(try r.u16le(), 1, "mono")
        XCTAssertEqual(try r.u32le(), 8000)
        XCTAssertEqual(try r.u32le(), 16_000, "byte rate")
        XCTAssertEqual(try r.u16le(), 2, "block align")
        XCTAssertEqual(try r.u16le(), 16, "bits per sample")
        XCTAssertEqual(String(decoding: try r.bytes(4), as: UTF8.self), "data")
        XCTAssertEqual(try r.u32le(), 16_000)
        XCTAssertTrue(r.rest().allSatisfy { $0 == 0 }, "digital silence")
    }

    func testSilentWAVStereoAndMinimumLength() throws {
        let wav = SilentWAV.make(sampleRate: 44_100, channels: 2, seconds: 0.5)
        var r = ByteReader(wav)
        try r.skip(22)
        XCTAssertEqual(try r.u16le(), 2)
        XCTAssertEqual(try r.u32le(), 44_100)
        XCTAssertEqual(try r.u32le(), 176_400)
        XCTAssertEqual(try r.u16le(), 4)
        XCTAssertEqual(wav.count, 44 + 22_050 * 4)
        XCTAssertEqual(SilentWAV.make(sampleRate: 8000, seconds: 0).count, 44 + 2, "at least one frame")
    }

    // MARK: Volume steps

    func testVolumeStepMath() {
        XCTAssertTrue(HandlebarVolumeMath.event(old: 0.5, new: 0.5625)! == (.volumeUp, 1))
        XCTAssertTrue(HandlebarVolumeMath.event(old: 0.5, new: 0.375)! == (.volumeDown, 2))
        XCTAssertTrue(HandlebarVolumeMath.event(old: 0.5, new: 0.6875)! == (.volumeUp, 3), "fast ▲▲ flick → ≥ 3 steps")
        XCTAssertNil(HandlebarVolumeMath.event(old: 0.5, new: 0.52), "less than half a step")
        XCTAssertNil(HandlebarVolumeMath.event(old: 0.25, new: 0.25))
        XCTAssertTrue(HandlebarVolumeMath.event(old: 0.0, new: 0.04)! == (.volumeUp, 1), "rounds to at least one step")
        XCTAssertEqual(HandlebarVolumeMath.stepSize, 1.0 / 16.0)
    }

    // MARK: Emitter

    func testEmitterStampsMonotonicTimeAndFansOut() async {
        final class Clock: MonotonicClock, @unchecked Sendable {
            func now() -> TimeInterval { 42.5 }
        }
        let emitter = HandlebarEventEmitter(clock: Clock())
        let received = Locked<[HandlebarRemoteEvent]>([])
        emitter.onEvent = { e in received.withLock { $0.append(e) } }
        let stream = emitter.stream()
        let e1 = emitter.emit(.select)
        emitter.emit(.volumeDown, steps: 3)
        XCTAssertEqual(e1, HandlebarRemoteEvent(raw: .select, time: 42.5))
        XCTAssertEqual(received.current, [HandlebarRemoteEvent(raw: .select, time: 42.5, steps: 1),
                                          HandlebarRemoteEvent(raw: .volumeDown, time: 42.5, steps: 3)])
        var it = stream.makeAsyncIterator()
        let first = await it.next()
        let second = await it.next()
        XCTAssertEqual(first?.raw, .select)
        XCTAssertEqual(second?.raw, .volumeDown)
        XCTAssertEqual(second?.steps, 3)
    }
}
