// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) TripStore.kt
//
// One compact JSON file per trip, `<id>.json`, in a directory (iOS: `Application Support/trips/`),
// byte-compatible with Android (app-features.md §5.5): object keys in the order
// `id, start, end, distanceMeters, movingTimeMs, maxSpeedMs, points`, points as
// `[lat, lon, timeMs, speedMs]`, AOSP `org.json` number formatting (`45.0` → `45`,
// `12.3f` → `12.300000190734863`, `1.0E-4`). Parsing uses AOSP's lenient `opt*` getters.
// Writes are atomic.

import Foundation

/// Errors thrown by `TripStore.save`.
public enum TripStoreError: Error, Equatable {
    /// The trip contains NaN / infinite numbers, which Android's org.json refuses to write.
    case nonFiniteNumber
}

public final class TripStore: @unchecked Sendable {
    /// The directory holding the trip files (created on demand).
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Codec

    /// The Android file content (compact JSON) or nil when a number is NaN/infinite (AOSP refuses).
    public static func encode(_ trip: Trip) -> String? {
        let doubles = [trip.distanceMeters, Double(trip.maxSpeedMs)]
            + trip.points.flatMap { [$0.lat, $0.lon, Double($0.speedMs)] }
        guard doubles.allSatisfy(\.isFinite) else { return nil }
        var o = OrderedJSONObject()
        o.put("id", trip.id)
        o.put("start", trip.start)
        o.put("end", trip.end)
        o.put("distanceMeters", trip.distanceMeters)
        o.put("movingTimeMs", trip.movingTimeMs)
        o.put("maxSpeedMs", Double(trip.maxSpeedMs))
        o.put("points", JSONValue.array(trip.points.map { p in
            .array([.double(p.lat), .double(p.lon), .int(p.timeMs), .double(Double(p.speedMs))])
        }))
        return AndroidOrgJSON.compact(.object(o))
    }

    /// Parses a trip file like Android (`optString/optLong/optDouble`; missing numbers → 0 / NaN;
    /// non-array points skipped). Nil when the text is not a JSON object.
    public static func decode(_ text: String) -> Trip? {
        guard let o = try? AndroidOrgJSON.parseObject(text) else { return nil }
        let arr = o.orgOptArray("points") ?? []
        var points: [TripPoint] = []
        points.reserveCapacity(arr.count)
        for i in arr.indices {
            guard let a = arr.orgOptArray(i) else { continue }
            points.append(TripPoint(lat: a.orgOptDouble(0), lon: a.orgOptDouble(1), timeMs: a.orgOptLong(2),
                                    speedMs: Float(a.orgOptDouble(3))))
        }
        return Trip(id: o.orgOptString("id"), start: o.orgOptLong("start"), end: o.orgOptLong("end"),
                    distanceMeters: o.orgOptDouble("distanceMeters"), movingTimeMs: o.orgOptLong("movingTimeMs"),
                    maxSpeedMs: Float(o.orgOptDouble("maxSpeedMs")), points: points)
    }

    /// File name for a trip: `<id>.json`; ids that are not a safe file stem fall back to the start time.
    public static func fileName(for trip: Trip) -> String {
        "\(safeStem(trip.id) ?? String(trip.start)).json"
    }

    private static func safeStem(_ id: String) -> String? {
        guard !id.isEmpty, !id.hasPrefix("."), id.utf8.count <= 128 else { return nil }
        let ok = id.unicodeScalars.allSatisfy { s in
            (s >= "0" && s <= "9") || (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || s == "_" || s == "-" || s == "."
        }
        return ok ? id : nil
    }

    // MARK: - Files

    private func url(forStem stem: String) -> URL {
        directory.appendingPathComponent(stem + ".json", isDirectory: false)
    }

    /// Writes the trip atomically (creating the directory). Throws on I/O errors or non-finite numbers.
    public func save(_ trip: Trip) throws {
        guard let text = Self.encode(trip) else {
            throw TripStoreError.nonFiniteNumber
        }
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: directory.appendingPathComponent(Self.fileName(for: trip)), options: .atomic)
    }

    /// Every parsable `*.json` trip, most recent first (`start` descending; ties by file name).
    public func list() -> [Trip] {
        lock.lock(); defer { lock.unlock() }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [(name: String, trip: Trip)] = []
        for name in names where name.hasSuffix(".json") {
            let u = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: u), let trip = Self.decode(String(decoding: data, as: UTF8.self)) else { continue }
            out.append((name, trip))
        }
        out.sort { a, b in a.trip.start != b.trip.start ? a.trip.start > b.trip.start : a.name > b.name }
        return out.map(\.trip)
    }

    /// The trip stored as `<id>.json`, if any.
    public func trip(id: String) -> Trip? {
        guard let stem = Self.safeStem(id) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url(forStem: stem)) else { return nil }
        return Self.decode(String(decoding: data, as: UTF8.self))
    }

    /// Deletes `<id>.json` (no error when missing).
    public func delete(id: String) {
        guard let stem = Self.safeStem(id) else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(forStem: stem))
    }
}
