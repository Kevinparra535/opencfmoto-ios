// SPDX-License-Identifier: AGPL-3.0-or-later
// TripsModel: live recorder stats, manual recording vs auto-log, day sections (grouping, order,
// localized titles / summaries), delete, GPX export, thumbnails (docs/spec/app-features.md §5).

import Foundation
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoAppModel

final class TripsModelTests: XCTestCase {

    static let utc = TimeZone(identifier: "UTC")!

    /// The repo vector trip (`test/TripGpxTest.kt`): 2023-11-14T22:13:20Z, 12.5 km in 6 min.
    static let vectorTrip = Trip(
        id: "1700000000000", start: 1_700_000_000_000, end: 1_700_000_360_000, distanceMeters: 12_500,
        movingTimeMs: 360_000, maxSpeedMs: 25,
        points: [TripPoint(lat: 45.0, lon: 25.0, timeMs: 1_700_000_000_000, speedMs: 10),
                 TripPoint(lat: 45.01, lon: 25.01, timeMs: 1_700_000_180_000, speedMs: 12)])

    @MainActor
    private func makeModel(_ env: LDTestEnv, locale: String = "en_US_POSIX", timeZone: TimeZone = utc,
                           language: NavLanguage = .en) async -> TripsModel {
        let trips = TripsModel(core: env.core)
        trips.locale = Locale(identifier: locale)
        trips.timeZone = timeZone
        trips.language = language
        trips.reload()
        await trips.pendingReload?.value
        return trips
    }

    // MARK: Sections

    @MainActor
    func testSectionsGroupByLocalDayNewestFirst() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let a = LDTest.trip(start: LDTest.epochMs("2026-10-31T09:00:00Z"), meters: 12_345.6)
        let b = LDTest.trip(start: LDTest.epochMs("2026-10-31T15:00:00Z"), meters: 1_000)
        let c = LDTest.trip(start: LDTest.epochMs("2026-10-30T22:30:00Z"), meters: 500)
        for t in [a, b, c] { try env.core.tripStore.save(t) }

        let trips = await makeModel(env)
        XCTAssertEqual(trips.sections.map(\.id), ["2026-10-31", "2026-10-30"])
        XCTAssertEqual(trips.sections.map(\.title), ["Sat 31 Oct 2026", "Fri 30 Oct 2026"])
        XCTAssertEqual(trips.sections.map(\.summary), ["2 rides \u{00B7} 13.3 km", "1 ride \u{00B7} 0.5 km"])
        XCTAssertEqual(trips.sections[0].trips.map(\.id), [b.id, a.id])   // newest trip first
        XCTAssertEqual(trips.sections[1].trips.map(\.id), [c.id])

        // Another time zone moves the day boundaries (calendar days, not Android's fixed 24 h).
        trips.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        trips.reload()
        await trips.pendingReload?.value
        XCTAssertEqual(trips.sections.map(\.id), ["2026-11-01", "2026-10-31"])
        XCTAssertEqual(trips.sections[0].trips.map(\.id), [b.id])
        XCTAssertEqual(trips.sections[1].trips.map(\.id), [a.id, c.id])
        XCTAssertEqual(trips.sections[1].summary, "2 rides \u{00B7} 12.8 km")
        XCTAssertEqual(trips.sections[1].title, "Sat 31 Oct 2026")
    }

    @MainActor
    func testSectionsInSpanish() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let a = LDTest.trip(start: LDTest.epochMs("2026-10-31T09:00:00Z"), meters: 12_345.6)
        let b = LDTest.trip(start: LDTest.epochMs("2026-10-31T15:00:00Z"), meters: 1_000)
        let c = LDTest.trip(start: LDTest.epochMs("2026-10-30T22:30:00Z"), meters: 500)
        for t in [a, b, c] { try env.core.tripStore.save(t) }

        let trips = await makeModel(env, locale: "es_ES", language: .es)
        XCTAssertEqual(trips.sections.map(\.summary), ["2 viajes \u{00B7} 13,3 km", "1 viaje \u{00B7} 0,5 km"])
        let day = LDTest.epochMs("2026-10-31T00:00:00Z")
        XCTAssertEqual(trips.sections[0].title,
                       TripFormat.dateText(epochMs: day, locale: Locale(identifier: "es_ES"), timeZone: Self.utc))
        XCTAssertNotEqual(trips.sections[0].title, "Sat 31 Oct 2026")
        XCTAssertTrue(trips.sections[0].title.contains("31"))
        XCTAssertTrue(trips.sections[0].title.hasSuffix("2026"))
    }

    func testDaySummaryStrings() {
        XCTAssertEqual(LogicData.Strings(.en).tripDaySummary(count: 1, distance: "0.5"), "1 ride \u{00B7} 0.5 km")
        XCTAssertEqual(LogicData.Strings(.en).tripDaySummary(count: 3, distance: "142.5"), "3 rides \u{00B7} 142.5 km")
        XCTAssertEqual(LogicData.Strings(.es).tripDaySummary(count: 1, distance: "0,5"), "1 viaje \u{00B7} 0,5 km")
        XCTAssertEqual(LogicData.Strings(.es).tripDaySummary(count: 2, distance: "12,3"), "2 viajes \u{00B7} 12,3 km")
        XCTAssertEqual(LogicData.Strings(.es).tripHasNoPoints, "El viaje no tiene puntos GPS")
    }

    // MARK: Recording

    @MainActor
    func testManualRecordingSavesTheRideAndAutoLogLeavesItAlone() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let trips = await makeModel(env)
        XCTAssertTrue(trips.sections.isEmpty)
        XCTAssertFalse(trips.isRecording)

        trips.startRecording()
        XCTAssertTrue(trips.isRecording)
        XCTAssertTrue(trips.isManualRecording)
        // RideModel's auto-log never stops a manual recording, even with logging off and no dash.
        XCTAssertEqual(TripAutoLogPolicy.action(logTrips: false, streaming: false, dashUILive: false,
                                                recording: trips.isRecording, manualRecording: trips.isManualRecording), .none)

        for fix in LDTest.rideFixes(count: 31, startMs: LDTest.epochMs("2026-10-31T09:00:00Z")) {
            env.core.tripRecorder.ingest(fix)
        }
        await LDTest.expect { trips.live.distanceMeters > 250 }
        XCTAssertTrue(trips.live.hasFix)
        XCTAssertEqual(trips.live.speedKmh, 36)
        XCTAssertEqual(trips.live.movingTimeMs, 30_000)

        trips.stopRecording()
        XCTAssertFalse(trips.isRecording)
        XCTAssertFalse(trips.isManualRecording)
        await LDTest.expect { trips.sections.count == 1 }
        let saved = try XCTUnwrap(trips.sections.first?.trips.first)
        XCTAssertEqual(saved.points.count, 31)
        XCTAssertEqual(trips.trip(id: saved.id)?.points.count, 31)

        // A leg that is too short is dropped (Android: ≥ 100 m and ≥ 15 s moving).
        trips.startRecording()
        trips.stopRecording()
        await LDTest.settle(0.05)
        XCTAssertEqual(trips.sections.flatMap(\.trips).count, 1)
    }

    @MainActor
    func testAutoLogStateChangesAndBackgroundStats() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let trips = await makeModel(env)
        let recorder = env.core.tripRecorder

        recorder.start()                 // RideModel's auto-log
        trips.recorderStateChanged()
        XCTAssertTrue(trips.isRecording)
        XCTAssertFalse(trips.isManualRecording)

        // Fixes fed from another thread reach `live` on the main actor.
        let fixes = LDTest.rideFixes(count: 3, startMs: 1_000_000)
        await Task.detached { for f in fixes { recorder.ingest(f) } }.value
        await LDTest.expect { trips.live.hasFix && trips.live.distanceMeters > 0 }

        // The rider takes over: auto-log can no longer stop it.
        trips.startRecording()
        XCTAssertTrue(trips.isManualRecording)
        XCTAssertEqual(TripAutoLogPolicy.action(logTrips: true, streaming: false, dashUILive: false,
                                                recording: true, manualRecording: trips.isManualRecording), .none)
        trips.stopRecording()

        recorder.start()
        trips.recorderStateChanged()
        recorder.stopAndSave()
        trips.recorderStateChanged()
        XCTAssertFalse(trips.isRecording)
        XCTAssertFalse(trips.isManualRecording)
    }

    @MainActor
    func testDiscardThrowsTheRideAwayWithoutSaving() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let trips = await makeModel(env)
        let recorder = env.core.tripRecorder

        // A manual ride long enough to be saved (≥ 100 m, ≥ 15 s moving)…
        trips.startRecording()
        for fix in LDTest.rideFixes(count: 31, startMs: LDTest.epochMs("2026-10-31T09:00:00Z")) {
            recorder.ingest(fix)
        }
        await LDTest.expect { trips.live.distanceMeters > 250 }

        // …is thrown away by Discard (Android "Reset"): recording off, trip computer at zero.
        trips.discardRecording()
        XCTAssertFalse(trips.isRecording)
        XCTAssertFalse(trips.isManualRecording)
        XCTAssertEqual(trips.live.distanceMeters, 0)
        XCTAssertEqual(trips.live.movingTimeMs, 0)
        XCTAssertEqual(trips.live.maxSpeedMs, 0)
        XCTAssertEqual(trips.live.speedKmh, 0)
        XCTAssertFalse(trips.live.hasFix)
        XCTAssertTrue(recorder.currentPoints.isEmpty)
        await LDTest.settle(0.05)
        XCTAssertTrue(trips.sections.isEmpty, "nothing saved")
        XCTAssertTrue(env.core.tripStore.list().isEmpty)
        trips.reload()
        await trips.pendingReload?.value
        XCTAssertTrue(trips.sections.isEmpty)

        // An automatic log is discarded the same way (RideModel's next check starts a fresh leg).
        recorder.start()
        trips.recorderStateChanged()
        XCTAssertFalse(trips.isManualRecording)
        for fix in LDTest.rideFixes(count: 31, startMs: LDTest.epochMs("2026-10-31T10:00:00Z")) {
            recorder.ingest(fix)
        }
        await LDTest.expect { trips.live.distanceMeters > 250 }
        trips.discardRecording()
        XCTAssertFalse(trips.isRecording)
        XCTAssertEqual(trips.live.distanceMeters, 0)
        await LDTest.settle(0.05)
        XCTAssertTrue(env.core.tripStore.list().isEmpty)

        // Discard with nothing recording is harmless; the next recording starts from zero.
        trips.discardRecording()
        XCTAssertFalse(trips.isRecording)
        trips.startRecording()
        XCTAssertTrue(trips.isManualRecording)
        XCTAssertEqual(trips.live.distanceMeters, 0)
        XCTAssertEqual(TripAutoLogPolicy.action(logTrips: true, streaming: true, dashUILive: true,
                                                recording: trips.isRecording, manualRecording: trips.isManualRecording), .none)
        trips.stopRecording()
        await LDTest.settle(0.05)
        XCTAssertTrue(trips.sections.isEmpty, "a leg without fixes is never saved")
    }

    // MARK: Delete

    @MainActor
    func testDeleteRemovesTheTripAndItsFile() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let a = LDTest.trip(start: LDTest.epochMs("2026-10-31T09:00:00Z"), meters: 2_000)
        let b = LDTest.trip(start: LDTest.epochMs("2026-10-30T09:00:00Z"), meters: 3_000)
        for t in [a, b] { try env.core.tripStore.save(t) }
        let trips = await makeModel(env)
        XCTAssertEqual(trips.sections.count, 2)

        trips.delete(a)
        XCTAssertEqual(trips.sections.map(\.id), ["2026-10-30"])
        XCTAssertNil(env.core.tripStore.trip(id: a.id))
        XCTAssertNil(trips.trip(id: a.id))
        trips.reload()
        await trips.pendingReload?.value
        XCTAssertEqual(trips.sections.flatMap(\.trips).map(\.id), [b.id])

        trips.delete(b)
        XCTAssertTrue(trips.sections.isEmpty)
        XCTAssertTrue(env.core.tripStore.list().isEmpty)
    }

    // MARK: GPX export

    @MainActor
    func testExportGPXMatchesTheAndroidTemplate() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let trips = await makeModel(env, locale: "en_US")
        let file = try trips.exportGPX(Self.vectorTrip)
        XCTAssertEqual(file.fileName, "opencfmoto_trip_20231114_2213.gpx")
        XCTAssertEqual(file.typeIdentifier, "com.topografix.gpx")
        XCTAssertEqual(file.url.deletingLastPathComponent().standardizedFileURL.path,
                       env.services.files.exportsDirectory.standardizedFileURL.path)
        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenCfMoto" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>OpenCfMoto Tue 14 Nov 2023 22:13 \u{2013} 22:19</name>
            <time>2023-11-14T22:13:20Z</time>
          </metadata>
          <trk>
            <name>OpenCfMoto Tue 14 Nov 2023 22:13 \u{2013} 22:19</name>
            <type>motorcycle</type>
            <trkseg>
              <trkpt lat="45.000000" lon="25.000000">
                <time>2023-11-14T22:13:20Z</time>
              </trkpt>
              <trkpt lat="45.010000" lon="25.010000">
                <time>2023-11-14T22:16:20Z</time>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>

        """
        XCTAssertEqual(LDTest.read(file), expected)
        XCTAssertNil(trips.lastError)
        // Parses back with the app's GPX parser.
        let parsed = GpxParser.parse(Data(LDTest.read(file).utf8))
        XCTAssertEqual(parsed.points.count, 2)
        XCTAssertEqual(parsed.points[1].lon, 25.01, accuracy: 1e-6)

        var empty = Self.vectorTrip
        empty.points = []
        XCTAssertThrowsError(try trips.exportGPX(empty)) { error in
            XCTAssertEqual(error.localizedDescription, LogicData.Strings(.en).tripHasNoPoints)
        }
        XCTAssertEqual(trips.lastError, "Trip has no GPS points")
    }

    // MARK: Thumbnails

    @MainActor
    func testThumbnailUsesTheAndroidGeometry() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let trips = await makeModel(env)

        // Worked example of app-features.md §5.10 (240×112 px).
        let pts = trips.thumbnail(for: Self.vectorTrip, width: 240, height: 112)
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(pts[0].x, 91.4919, accuracy: 1e-3)
        XCTAssertEqual(pts[0].y, 96.3200, accuracy: 1e-3)
        XCTAssertEqual(pts[1].x, 148.5081, accuracy: 1e-3)
        XCTAssertEqual(pts[1].y, 15.6800, accuracy: 1e-3)
        XCTAssertEqual(trips.thumbnail(for: Self.vectorTrip, width: 240, height: 112), pts)   // cached, stable

        // The mapping is linear in the size: half the size → half the coordinates.
        let half = trips.thumbnail(for: Self.vectorTrip, width: 120, height: 56)
        for (p, q) in zip(half, pts) {
            XCTAssertEqual(p.x * 2, q.x, accuracy: 1e-3)
            XCTAssertEqual(p.y * 2, q.y, accuracy: 1e-3)
        }
        // Fractional point sizes (SwiftUI layout) scale the same way.
        let fractional = trips.thumbnail(for: Self.vectorTrip, width: 60.5, height: 28.25)
        let reference = trips.thumbnail(for: Self.vectorTrip, width: 242, height: 113)
        XCTAssertEqual(fractional.count, reference.count)
        for (p, q) in zip(fractional, reference) {
            XCTAssertEqual(p.x * 4, q.x, accuracy: 1e-2)
            XCTAssertEqual(p.y * 4, q.y, accuracy: 1e-2)
        }

        var single = Self.vectorTrip
        single.points = Array(single.points.prefix(1))
        XCTAssertTrue(trips.thumbnail(for: single, width: 240, height: 112).isEmpty)
        XCTAssertTrue(trips.thumbnail(for: Self.vectorTrip, width: 0, height: 112).isEmpty)
        XCTAssertTrue(trips.thumbnail(for: Self.vectorTrip, width: .nan, height: 112).isEmpty)
    }
}
