// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) OfflineRouter.kt
//
// Routing decision tree (docs/spec/navigation-dash.md §6.1):
//   avoids requested: ORS (if key, strict avoid_features) → Valhalla (motorcycle exclude_highways /
//                     use_tolls 0) → OSRM fallback without avoids (avoidHonored = false + warning)
//   no avoids:        Valhalla corridor alternates (previews) + OSRM (+ via-offset "Alt" fill) →
//                     ORS without avoids (if key) → straight-line "Direct"
//   circuit:          one start → dest → start request; else A→B + B→A concatenated.
// Labels Fast / Fun / Alt / Circuit / Direct, dedupe and same-corridor tolerances and the via
// "junk" filter are verbatim.
//
// Not ported: the on-device A* road graph (`OfflineRoadGraph`, §6.7 — optional for iOS v1); its
// two branches (offline single route, offline avoid-highways) are simply skipped.

import Foundation

/// Picks routers, builds alternatives and labels them. Thread-safe; all methods are `async` and
/// sequential like Android's worker thread. Cancellation stops further network requests.
public final class RouteOrchestrator: @unchecked Sendable {
    public static let warningAvoidFallback = "Couldn't avoid highways/tolls online — showing normal (may use motorway)"
    public static let warningCircuitAvoid = "Couldn't avoid highways/tolls — circuit may use motorway"
    public static let errorCircuit = "Couldn't build there-and-back circuit"
    public static let errorCircuitFailed = "Circuit failed"

    public let osrm: OsrmRouter
    public let valhalla: ValhallaRouter
    public let ors: OrsRouter
    private let key: Locked<String>

    /// - Parameters:
    ///   - http: transport for all three routers (wrap it in `ThrottledHTTPClient`).
    ///   - orsApiKey: optional OpenRouteService key (blank = ORS unused).
    public init(http: HTTPClient, orsApiKey: String = "") {
        osrm = OsrmRouter(http: http)
        valhalla = ValhallaRouter(http: http)
        ors = OrsRouter(http: http)
        key = Locked(orsApiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The rider's ORS key (trimmed). iOS has no build-time default key (spec R5).
    public var orsApiKey: String {
        get { key.current }
        set { key.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    // MARK: - Entry points

    /// Single best route for navigation start without a cached preview and for reroutes
    /// (`routeAsync`). Never fails: worst case a straight line labelled "Direct".
    public func route(from: GeoPoint, to: GeoPoint, options: RouteOptions) async -> Route {
        let r = await computeRoutes(from: from, to: to, options: options, wantAlts: false)
        return r.routes.first ?? Self.beeline(from: from, to: to).withLabel("Direct")
    }

    /// Preview options (`routeAlternativesDetailedAsync`): up to 3 (≤ 100 km) or 5 routes labelled
    /// Fast / Fun / Alt, index 0 pre-selected. Never fails (beeline fallback).
    public func alternatives(from: GeoPoint, to: GeoPoint, options: RouteOptions) async -> RouteResult {
        await computeRoutes(from: from, to: to, options: options, wantAlts: true)
    }

    /// Out-and-back circuit start → destination → start (`circuitAlternativesAsync`). Returns one
    /// route labelled "Circuit"; throws `NavServiceError.service` when nothing could be built.
    public func circuit(from: GeoPoint, to: GeoPoint, options: RouteOptions) async throws -> RouteResult {
        let out = await computeOutAndBack(from: from, to: to, options: options)
        if out.routes.isEmpty { throw NavServiceError.service(out.warning ?? Self.errorCircuit) }
        Log.i("NAV", "[route] circuit out-and-back \(out.routes.count) option(s)" + (out.warning.map { " warn=\($0)" } ?? ""))
        return out
    }

    // MARK: - Circuit

    func computeOutAndBack(from: GeoPoint, to: GeoPoint, options opts: RouteOptions) async -> RouteResult {
        let orsKey = orsApiKey
        let approxKm = GeoMath.haversineKm(from.lat, from.lon, to.lat, to.lon)
        Log.i("NAV", "[route] circuit out-and-back ~\(Int(approxKm * 2))km round-trip avoids=\(opts.wantsAvoids) orsKey=\(!orsKey.isEmpty)")
        var merged: [Route] = []
        var warning: String?
        var avoidHonored = !opts.wantsAvoids
        var usedAvoidEngine = false

        func fetch(_ vias: [GeoPoint], _ label: String) async -> [Route] {
            if opts.wantsAvoids && !orsKey.isEmpty && !Task.isCancelled {
                let hit = (try? await ors.routes(apiKey: orsKey, from: from, to: from, options: opts, vias: vias,
                                                  alternatives: false, label: label)) ?? []
                if !hit.isEmpty { usedAvoidEngine = true; return hit }
            }
            if opts.wantsAvoids && !Task.isCancelled {
                let hit = (try? await valhalla.routes(from: from, to: from, options: opts, vias: vias,
                                                       alternatives: 0, label: label)) ?? []
                if !hit.isEmpty { usedAvoidEngine = true; return hit }
            }
            if Task.isCancelled { return [] }
            return (try? await osrm.routes(from: from, to: from, alternatives: 0, vias: vias, label: label)) ?? []
        }

        merged.append(contentsOf: await fetch([to], "Circuit"))
        if merged.isEmpty {
            let out = await computeRoutes(from: from, to: to, options: opts, wantAlts: false)
            let back = await computeRoutes(from: to, to: from, options: opts, wantAlts: false)
            if let a = out.routes.first, let b = back.routes.first, a.points.count >= 2, b.points.count >= 2 {
                warning = out.warning ?? back.warning
                avoidHonored = out.avoidHonored && back.avoidHonored
                merged.append(Route(points: a.points + b.points.dropFirst(), distanceM: a.distanceM + b.distanceM,
                                    durationSec: a.durationSec + b.durationSec, steps: a.steps + b.steps, label: "Circuit"))
            } else {
                warning = out.warning ?? back.warning ?? Self.errorCircuit
            }
        } else if opts.wantsAvoids {
            avoidHonored = usedAvoidEngine
            if !usedAvoidEngine { warning = Self.warningCircuitAvoid }
        }
        let one = Self.dedupe(merged).first?.withLabel("Circuit")
        return RouteResult(routes: one.map { [$0] } ?? [], avoidHonored: avoidHonored, warning: warning)
    }

    // MARK: - computeRoutes

    func computeRoutes(from: GeoPoint, to: GeoPoint, options opts: RouteOptions, wantAlts: Bool,
                       forcedVias: [GeoPoint] = [], forceLabel: String? = nil) async -> RouteResult {
        let approxKm = GeoMath.haversineKm(from.lat, from.lon, to.lat, to.lon)
        let orsKey = orsApiKey
        Log.i("NAV", "[route] request ~\(Int(approxKm))km mode=\(opts.mode.rawValue) alts=\(wantAlts) avoids=\(opts.wantsAvoids) orsKey=\(!orsKey.isEmpty) vias=\(forcedVias.count)")
        // (Android: offline graph first when !wantAlts && !avoids && no vias — not ported.)
        if opts.wantsAvoids {
            if !orsKey.isEmpty {
                let avoided = await routeWithAvoids(orsKey: orsKey, from: from, to: to, opts: opts, wantAlts: wantAlts,
                                                    forcedVias: forcedVias, forceLabel: forceLabel, approxKm: approxKm)
                if !avoided.isEmpty {
                    return RouteResult(routes: Self.finalizeAvoid(avoided, forceLabel: forceLabel, wantAlts: wantAlts,
                                                                  approxKm: approxKm, mode: opts.mode), avoidHonored: true)
                }
            }
            let valhallaRoutes = await routeWithValhallaAvoid(from: from, to: to, opts: opts, wantAlts: wantAlts,
                                                              forcedVias: forcedVias, forceLabel: forceLabel, approxKm: approxKm)
            if !valhallaRoutes.isEmpty {
                Log.i("NAV", "[route] Valhalla avoid OK — \(valhallaRoutes.count) option(s)")
                return RouteResult(routes: Self.finalizeAvoid(valhallaRoutes, forceLabel: forceLabel, wantAlts: wantAlts,
                                                              approxKm: approxKm, mode: opts.mode), avoidHonored: true)
            }
            // (Android: offline avoid-highways graph — not ported.)
            let msg = Self.warningAvoidFallback
            Log.i("NAV", "[route] \(msg) — OSRM fallback")
            var fast = opts
            fast.mode = .fast
            fast.avoidTolls = false
            fast.avoidHighways = false
            let fallback = await cloudWithoutAvoids(from: from, to: to, opts: fast, wantAlts: false, forcedVias: forcedVias,
                                                    forceLabel: forceLabel ?? "Fast", orsKey: orsKey)
            return RouteResult(routes: fallback, avoidHonored: false, warning: msg)
        }
        let routes = await cloudWithoutAvoids(from: from, to: to, opts: opts, wantAlts: wantAlts, forcedVias: forcedVias,
                                              forceLabel: forceLabel, orsKey: orsKey)
        return RouteResult(routes: routes, avoidHonored: true)
    }

    /// ORS with avoid_features; mild corridor alternatives only.
    private func routeWithAvoids(orsKey: String, from: GeoPoint, to: GeoPoint, opts: RouteOptions, wantAlts: Bool,
                                 forcedVias: [GeoPoint], forceLabel: String?, approxKm: Double) async -> [Route] {
        var merged: [Route] = []
        let orsAlts = wantAlts && forcedVias.isEmpty && approxKm < 90.0
        let primaryLabel = forceLabel ?? ValhallaRouter.avoidLabel(opts)
        func call(_ alts: Bool, _ vias: [GeoPoint], _ label: String) async -> [Route] {
            if Task.isCancelled { return [] }
            do {
                return try await ors.routes(apiKey: orsKey, from: from, to: to, options: opts, vias: vias,
                                            alternatives: alts, label: label)
            } catch {
                Log.i("NAV", "[route] ORS avoid fail alts=\(alts) vias=\(vias.count): \(NavServiceError.message(for: error, fallback: "error"))")
                return []
            }
        }
        merged.append(contentsOf: await call(orsAlts, forcedVias, primaryLabel))
        if merged.isEmpty { merged.append(contentsOf: await call(false, forcedVias, primaryLabel)) }
        // Longer trips only — short via offsets often invent spur U-turns.
        if wantAlts && forcedVias.isEmpty && approxKm >= 50.0 && !merged.isEmpty && merged.count < 2,
           let vias = FunRoutePlanner.altViaSets(from: from, to: to).first {
            merged.append(contentsOf: await call(false, vias, "Alt"))
        }
        if !merged.isEmpty { Log.i("NAV", "[route] ORS avoid OK — \(merged.count) option(s)") }
        return merged
    }

    /// Valhalla motorcycle exclude_highways — works without a key.
    private func routeWithValhallaAvoid(from: GeoPoint, to: GeoPoint, opts: RouteOptions, wantAlts: Bool,
                                        forcedVias: [GeoPoint], forceLabel: String?, approxKm: Double) async -> [Route] {
        if Task.isCancelled { return [] }
        let label = forceLabel ?? ValhallaRouter.avoidLabel(opts)
        let alts: Int
        if !wantAlts || !forcedVias.isEmpty { alts = 0 } else if approxKm > 100.0 { alts = 3 } else if approxKm < 50.0 { alts = 1 } else { alts = 2 }
        do {
            return try await valhalla.routes(from: from, to: to, options: opts, vias: forcedVias, alternatives: alts, label: label)
        } catch {
            Log.i("NAV", "[route] Valhalla avoid fail: \(NavServiceError.message(for: error, fallback: "error"))")
            return []
        }
    }

    /// Avoid previews still use the Fast / Fun / Alt order of the active mode.
    static func finalizeAvoid(_ routes: [Route], forceLabel: String?, wantAlts: Bool, approxKm: Double,
                              mode: RouteMode) -> [Route] {
        if !wantAlts {
            guard let best = minByDuration(dedupe(routes)) else { return [] }
            return [best.withLabel(forceLabel ?? "Fast")]
        }
        let picked = pickPreviewRoutes(routes, approxKm: approxKm, mode: mode, forceLabel: forceLabel)
        Log.i("NAV", "[route] avoid \(picked.count) option(s): " + picked.map { "\($0.label)/\(Int($0.distanceM / 1000))km/\(Int($0.durationSec))s" }.joined(separator: ", "))
        return picked
    }

    /// Routing without avoid flags (Valhalla corridor alternates first for previews, then OSRM,
    /// ORS without avoids, via-offset "Alt" fill on previews, and the straight-line fallback).
    private func cloudWithoutAvoids(from: GeoPoint, to: GeoPoint, opts: RouteOptions, wantAlts: Bool,
                                    forcedVias: [GeoPoint], forceLabel: String?, orsKey: String) async -> [Route] {
        var merged: [Route] = []
        let approxKm = GeoMath.haversineKm(from.lat, from.lon, to.lat, to.lon)
        let longTrip = approxKm > 100.0
        let shortTrip = approxKm < 50.0
        let osrmAlts: Int
        if !wantAlts || !forcedVias.isEmpty { osrmAlts = 0 } else if longTrip { osrmAlts = 1 } else { osrmAlts = 2 }

        func callOsrm(_ alts: Int, _ vias: [GeoPoint], _ label: String) async -> [Route] {
            if Task.isCancelled { return [] }
            do {
                return try await osrm.routes(from: from, to: to, alternatives: alts, vias: vias, label: label)
            } catch {
                Log.i("NAV", "[route] OSRM fail alts=\(alts) vias=\(vias.count): \(NavServiceError.message(for: error, fallback: "error"))")
                return []
            }
        }

        if wantAlts && forcedVias.isEmpty && !Task.isCancelled {
            var noAvoid = opts
            noAvoid.avoidTolls = false
            noAvoid.avoidHighways = false
            do {
                merged.append(contentsOf: try await valhalla.routes(from: from, to: to, options: noAvoid,
                                                                    alternatives: longTrip ? 3 : 2, label: forceLabel ?? "Fast"))
            } catch {
                Log.i("NAV", "[route] Valhalla alts fail: \(NavServiceError.message(for: error, fallback: "error"))")
            }
        }
        merged.append(contentsOf: await callOsrm(osrmAlts, forcedVias, forceLabel ?? ""))
        if merged.isEmpty { merged.append(contentsOf: await callOsrm(0, forcedVias, forceLabel ?? "")) }

        if merged.isEmpty && !orsKey.isEmpty && !Task.isCancelled {
            var noAvoid = opts
            noAvoid.avoidTolls = false
            noAvoid.avoidHighways = false
            do {
                merged.append(contentsOf: try await ors.routes(apiKey: orsKey, from: from, to: to, options: noAvoid,
                                                               vias: forcedVias, alternatives: false, label: forceLabel ?? ""))
            } catch {
                Log.i("NAV", "[route] ORS (no avoid) fail: \(NavServiceError.message(for: error, fallback: "error"))")
            }
        }

        // Extra corridors via offsets — kept ONLY without U-turns / cul-de-sac spurs.
        if wantAlts && forcedVias.isEmpty && !merged.isEmpty {
            let need = longTrip ? 5 : 3
            if Self.dedupe(merged, approxKm: approxKm).count < need {
                let viaSets: [[GeoPoint]]
                if shortTrip {
                    viaSets = FunRoutePlanner.shortViaSets(from: from, to: to)
                } else {
                    viaSets = Array(FunRoutePlanner.funViaSets(from: from, to: to).prefix(longTrip ? 2 : 1))
                        + Array(FunRoutePlanner.altViaSets(from: from, to: to).prefix(longTrip ? 2 : 1))
                }
                for vias in viaSets {
                    if Self.dedupe(merged, approxKm: approxKm).count >= need + 1 { break }
                    for r in await callOsrm(0, vias, "Alt") {
                        if Self.isViaJunk(r) {
                            Log.i("NAV", "[route] drop spur/via junk \(Int(r.distanceM / 1000))km")
                        } else {
                            merged.append(r)
                        }
                    }
                }
            }
            Log.i("NAV", "[route] candidates=\(merged.count) after via fill")
        }

        let finalized = Self.finalize(merged, mode: opts.mode, forceLabel: forceLabel, wantAlts: wantAlts, approxKm: approxKm)
        if !finalized.isEmpty { return finalized }
        Log.i("NAV", "[route] online failed — beeline fallback (~\(Int(approxKm))km) (enable mobile data while projecting — bike Wi‑Fi has no internet)")
        return [Self.beeline(from: from, to: to).withLabel(forceLabel ?? "Direct")]
    }

    static func finalize(_ routes: [Route], mode: RouteMode, forceLabel: String?, wantAlts: Bool, approxKm: Double) -> [Route] {
        if !wantAlts {
            guard let best = minByDuration(dedupe(routes, approxKm: approxKm)) else { return [] }
            return [best.withLabel(forceLabel ?? (mode == .fun ? "Fun" : "Fast"))]
        }
        let picked = pickPreviewRoutes(routes, approxKm: approxKm, mode: mode, forceLabel: forceLabel)
        Log.i("NAV", "[route] \(picked.count) option(s): " + picked.map { "\($0.label)/\(Int($0.distanceM / 1000))km/\(Int($0.durationSec))s" }.joined(separator: ", "))
        return picked
    }

    // MARK: - Preview selection

    /// Preview chips: FAST mode → Fast, Fun, Alt; FUN mode → Fun, Fast, Alt; ≤ 100 km → max 3,
    /// > 100 km → up to 5 (extra Alts outside every core corridor).
    public static func pickPreviewRoutes(_ routes: [Route], approxKm: Double, mode: RouteMode, forceLabel: String?) -> [Route] {
        let maxTotal = approxKm > 100.0 ? 5 : 3
        let distinct = navStableSorted(dedupe(routes, approxKm: approxKm), by: { $0.durationSec })
        guard let fastRaw = distinct.first else { return [] }
        let rest = distinct.filter { !sameCorridor($0, fastRaw, approxKm: approxKm) }
        var funRaw: Route?
        var funScore = -Double.infinity
        for r in rest {
            let s = FunRoutePlanner.twistScore(r)
            if funRaw == nil || s > funScore { funRaw = r; funScore = s }
        }
        let altRaw = minByDuration(rest.filter { funRaw == nil || !sameCorridor($0, funRaw!, approxKm: approxKm) })
        let hasForce = !(forceLabel ?? "").isNavBlank
        let fast = fastRaw.withLabel(hasForce && mode == .fast ? forceLabel! : "Fast")
        let funR = funRaw?.withLabel(hasForce && mode == .fun ? forceLabel! : "Fun")
        let alt = altRaw?.withLabel("Alt")
        let core: [Route]
        switch mode {
        case .fun: core = [funR, fast, alt].compactMap { $0 }
        case .fast: core = [fast, funR, alt].compactMap { $0 }
        }
        if approxKm <= 100.0 || core.count >= maxTotal { return Array(core.prefix(maxTotal)) }
        let extras = navStableSorted(rest.filter { r in !core.contains { sameCorridor($0, r, approxKm: approxKm) } },
                                  by: { $0.durationSec })
            .prefix(maxTotal - core.count)
            .map { $0.withLabel("Alt") }
        return Array((core + extras).prefix(maxTotal))
    }

    /// Same corridor: |Δdistance| < 500 m and |Δduration| < 90 s (approxKm < 50), else 1 500 m / 180 s.
    public static func sameCorridor(_ a: Route, _ b: Route, approxKm: Double) -> Bool {
        let distTol = approxKm < 50.0 ? 500.0 : 1_500.0
        let timeTol = approxKm < 50.0 ? 90.0 : 180.0
        return abs(a.distanceM - b.distanceM) < distTol && abs(a.durationSec - b.durationSec) < timeTol
    }

    /// Drops near-duplicates: |Δdistance| < 200 m and |Δduration| < 40 s (approxKm < 50), else
    /// 800 m / 120 s. First occurrence wins. Default approxKm 100 like Android.
    public static func dedupe(_ routes: [Route], approxKm: Double = 100.0) -> [Route] {
        let distTol = approxKm < 50.0 ? 200.0 : 800.0
        let timeTol = approxKm < 50.0 ? 40.0 : 120.0
        var out: [Route] = []
        for r in routes {
            let dup = out.contains { abs($0.distanceM - r.distanceM) < distTol && abs($0.durationSec - r.durationSec) < timeTol }
            if !dup { out.append(r) }
        }
        return out
    }

    private static func minByDuration(_ routes: [Route]) -> Route? {
        var best: Route?
        for r in routes where best == nil || r.durationSec < best!.durationSec { best = r }
        return best
    }

    // MARK: - Via junk filter

    /// Offset-via junk: mid-route U-turn, local street ping-pong, or tight cul-de-sac spur.
    public static func isViaJunk(_ route: Route) -> Bool {
        hasMidRouteUturn(route) || hasRoadNamePingPong(route) || hasTightCulDeSacSpur(route.points)
    }

    static func hasMidRouteUturn(_ route: Route) -> Bool {
        if route.steps.count < 3 { return false }
        return route.steps[1 ..< route.steps.count - 1].contains { step in
            let mod = step.modifier?.lowercased() ?? ""
            let type = step.maneuverType.lowercased()
            return mod.contains("uturn") || type.contains("uturn") || mod.contains("u-turn") || type.contains("u-turn")
        }
    }

    /// The same local street comes back 40–500 m further along → dead-end spur.
    static func hasRoadNamePingPong(_ route: Route) -> Bool {
        var along = 0.0
        var last: [String: Double] = [:]
        let lastIndex = route.steps.count - 1
        for (idx, step) in route.steps.enumerated() {
            if idx == 0 || idx == lastIndex {
                along += step.distanceM
                continue
            }
            let name = step.roadName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !isLocalStreetName(name) {
                along += step.distanceM
                continue
            }
            if let prev = last[name] {
                let gap = along - prev
                if gap >= 40.0 && gap <= 500.0 { return true }
            }
            last[name] = along
            along += step.distanceM
        }
        return false
    }

    private static let nationalRoadRef = try! NSRegularExpression(pattern: #"^(dn|dj|dr|a|e)\s*\d.*$"#, options: [])

    /// Romanian local street names ("strada…", "aleea…", "intrarea…"), never DN/DJ/A/E refs.
    static func isLocalStreetName(_ name: String) -> Bool {
        if name.count < 5 || name == "-" || name == "unnamed road" { return false }
        let range = NSRange(name.startIndex ..< name.endIndex, in: name)
        if let m = nationalRoadRef.firstMatch(in: name, options: [], range: range), m.range == range { return false }
        if name.hasPrefix("autostrada") || name.hasPrefix("centura") { return false }
        if name.hasPrefix("bulevard") || name.hasPrefix("calea ") { return false }
        return name.hasPrefix("strada") || name.hasPrefix("aleea") || name.hasPrefix("intrarea")
    }

    /// Geometry returns within 25 m of an earlier point after only 60–450 m of travel (samples
    /// ≥ 20 m apart; needs ≥ 10 raw / ≥ 8 resampled points).
    static func hasTightCulDeSacSpur(_ points: [TrackPoint]) -> Bool {
        if points.count < 10 { return false }
        var sample: [TrackPoint] = []
        var cum: [Double] = []
        var dist = 0.0
        var last: TrackPoint?
        for p in points {
            if let prev = last { dist += GeoMath.haversineM(prev.lat, prev.lon, p.lat, p.lon) }
            if last == nil || dist - (cum.last ?? -1e9) >= 20.0 {
                sample.append(p)
                cum.append(dist)
            }
            last = p
        }
        if sample.count < 8 { return false }
        for i in sample.indices {
            let di = cum[i]
            var j = i - 1
            while j >= 0 {
                let gap = di - cum[j]
                if gap < 60.0 { j -= 1; continue }
                if gap > 450.0 { break }
                if GeoMath.haversineM(sample[i].lat, sample[i].lon, sample[j].lat, sample[j].lon) < 25.0 { return true }
                j -= 1
            }
        }
        return false
    }

    // MARK: - Beeline

    /// Straight line: `clamp(dist/2000, 2, 200)` segments, duration `dist / 13.9` s, steps
    /// [depart "Head toward destination (offline)", arrive "Destination"], no label.
    public static func beeline(from: GeoPoint, to: GeoPoint) -> Route {
        let distM = GeoMath.haversineM(from.lat, from.lon, to.lat, to.lon)
        let n = min(max(NavNumberFormat.truncateToInt(distM / 2000.0), 2), 200)
        let pts = (0 ... n).map { i -> TrackPoint in
            let t = Double(i) / Double(n)
            return TrackPoint(lat: from.lat + (to.lat - from.lat) * t, lon: from.lon + (to.lon - from.lon) * t)
        }
        let depart = RouteStep(maneuverType: "depart", modifier: nil, roadName: "Head toward destination (offline)",
                               maneuverLat: from.lat, maneuverLon: from.lon, distanceM: distM)
        let arrive = RouteStep(maneuverType: "arrive", modifier: nil, roadName: "Destination",
                               maneuverLat: to.lat, maneuverLon: to.lon, distanceM: 0)
        return Route(points: pts, distanceM: distM, durationSec: distM / 13.9, steps: [depart, arrive])
    }
}

public extension Route {
    /// Copy with another chip label (`Route.withLabel`).
    func withLabel(_ label: String) -> Route {
        var r = self
        r.label = label
        return r
    }

    /// True for the straight-line fallback or any step flagged "offline" (preview meta prefix).
    var isDirectFallback: Bool {
        label.caseInsensitiveCompare("Direct") == .orderedSame
            || steps.contains { $0.roadName.range(of: "offline", options: .caseInsensitive) != nil }
    }
}
