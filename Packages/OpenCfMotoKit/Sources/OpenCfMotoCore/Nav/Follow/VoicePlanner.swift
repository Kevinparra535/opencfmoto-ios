// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxVoice.kt
//
// Decides WHAT to say and WHEN (docs/spec/navigation-dash.md §5); speaking is the app's job
// (`NavEffect.speak`, QUEUE_FLUSH semantics, AVSpeechSynthesizer on iOS).

import Foundation

/// Turn-by-turn voice scheduler (Android `GpxVoice` minus the TTS engine).
///
/// Google/Waze style: one heads-up at `clamp(v·14, 150, 700)` m ("In 300 meters, turn right onto
/// Main St"), one at the junction within `clamp(v·1.6, 25, 60)` m ("Turn right onto Main St"),
/// a waypoint cue within 120 m, and join-route compass cues while off the route (on band change or
/// every 18 s).
public struct VoicePlanner: Sendable, Equatable {
    public var strings: NavStrings
    public private(set) var preparedIdx: Int = .min
    public private(set) var executedIdx: Int = .min
    public private(set) var lastWaypointKey: String?
    public private(set) var lastJoinSpeakMs: Int64?
    public private(set) var lastJoinDir: TurnDir?

    /// Minimum gap between repeated join-route cues with an unchanged direction band.
    public static let joinRepeatMs: Int64 = 18_000
    /// Waypoint announcement radius (m).
    public static let waypointRadiusM = 120.0

    public init(strings: NavStrings = .english) { self.strings = strings }

    /// Heads-up distance: `clamp(speed·14, 150, 700)` m.
    public static func prepareDistanceM(speedMps: Double) -> Double {
        min(max(Double(Float(speedMps)) * 14.0, 150.0), 700.0)
    }

    /// Execute ("at the junction") distance: `clamp(speed·1.6, 25, 60)` m.
    public static func executeDistanceM(speedMps: Double) -> Double {
        min(max(Double(Float(speedMps)) * 1.6, 25.0), 60.0)
    }

    /// Forgets all announcement state (new route / new navigation).
    public mutating func reset() {
        preparedIdx = .min
        executedIdx = .min
        lastWaypointKey = nil
        lastJoinSpeakMs = nil
        lastJoinDir = nil
    }

    /// Turn and waypoint cues for one progress update (`GpxVoice.onProgress`). Returns the phrases
    /// to speak in order (usually zero or one). Ignored while off route (> 40 m): the join-route
    /// cues own the voice then.
    public mutating func onProgress(_ p: RouteProgress, units: MapUnits, speedMps: Double) -> [String] {
        if p.offTrackM > RouteFollower.offRouteGuideM { return [] }
        lastJoinDir = nil
        var out: [String] = []
        if let turn = p.upcomingTurn {
            let d = turn.distanceFromRiderM
            let prepareM = Self.prepareDistanceM(speedMps: speedMps)
            let executeM = Self.executeDistanceM(speedMps: speedMps)
            let phrase = turn.instr.isNavBlank ? strings.dirPhrase(turn.dir) : turn.instr
            if d <= executeM {
                if executedIdx != turn.index {
                    executedIdx = turn.index
                    preparedIdx = turn.index // don't fire the heads-up afterwards
                    out.append(phrase.navCapitalizedFirst)
                }
            } else if d <= prepareM {
                if preparedIdx != turn.index {
                    preparedIdx = turn.index
                    out.append(strings.inDistance(strings.spokenDistance(d, units), phrase))
                }
            }
        }
        if let w = p.nextWaypoint, let wM = p.nextWaypointM, wM <= Self.waypointRadiusM {
            let key = NavNumberFormat.javaString(w.lat) + "," + NavNumberFormat.javaString(w.lon)
            if key != lastWaypointKey {
                lastWaypointKey = key
                out.append(strings.phrase(.approaching(w.name)))
            }
        }
        return out
    }

    /// Compass guidance while off the road (`GpxVoice.onJoinRoute`): speaks when the direction band
    /// changed or ≥ 18 s since the last join cue, e.g. "Turn left toward the route, 120 m".
    public mutating func onJoinRoute(dir: TurnDir, offTrackM: Double, units: MapUnits, nowMs: Int64) -> String? {
        let changed = dir != lastJoinDir
        let due = lastJoinSpeakMs.map { nowMs - $0 > Self.joinRepeatMs } ?? true
        if !changed && !due { return nil }
        lastJoinDir = dir
        lastJoinSpeakMs = nowMs
        return strings.joinRouteSpeak(dir).navCapitalizedFirst + ", " + strings.distance(offTrackM, units)
    }
}
