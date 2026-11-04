// SPDX-License-Identifier: AGPL-3.0-or-later
// The raster tile source of the dash map (`BikeSettings.tileURLTemplate`) and the two rules that follow
// from it — docs/spec/navigation-dash.md §10.4 (iOS). Pure and unit-tested on Linux:
// - The OpenStreetMap Foundation tile servers (tile.openstreetmap.org, the default; its legacy
//   a. / b. / c.tile aliases; any other *.openstreetmap.org or *.osm.org host) forbid prefetching and
//   offline or bulk downloads (OSMF Tile Usage Policy). The route-corridor prefetch therefore runs only
//   for a tile server the rider configured (`allowsCorridorPrefetch`).
// - Their tiles need a visible credit next to the map: the dash draws "© OpenStreetMap" in a free
//   corner of the map (`attribution` → `DashModel.mapAttribution`). Other servers get no label.
//
// When in doubt the rules choose the OSMF side: a template whose host cannot be read never prefetches,
// and a template counts as OSMF when any reading of its host (this parser, or Foundation's `URL`, which
// the downloader uses) is an OSMF host.

import Foundation

public enum MapTileSource {
    /// The credit drawn on the dash map next to tiles from the OSMF servers.
    public static let openStreetMapCredit = "© OpenStreetMap"

    /// Domains of the OSMF tile servers (the domain itself and every subdomain); osm.org is the
    /// Foundation's short domain.
    static let osmfDomains = ["openstreetmap.org", "osm.org"]

    /// True when `host` belongs to the OpenStreetMap Foundation: openstreetmap.org, osm.org or any of their
    /// subdomains (tile.openstreetmap.org, a.tile.openstreetmap.org …). Case, a trailing dot and a port
    /// are ignored; look-alikes such as openstreetmap.org.example.com or notopenstreetmap.org are not OSMF.
    public static func isOpenStreetMapFoundation(host: String) -> Bool {
        guard let h = normalized(host) else { return false }
        return osmfDomains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// Every host a reader of the template could connect to (lower-cased, without port or trailing dot):
    /// the authority of `scheme://authority/…` read per RFC 3986 (userinfo before the last "@" dropped;
    /// "{…}" placeholders lose their braces, so `{s}.tile.openstreetmap.org` reads as
    /// s.tile.openstreetmap.org), plus Foundation's `URL.host` when it differs. Empty when no host can
    /// be read.
    public static func hosts(template: String) -> [String] {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [String] = []
        if let h = rfcHost(t) { out.append(h) }
        // The downloader (`TileURLTemplate.url`) fills {z}/{x}/{y} and asks Foundation's URL for the host.
        let filled = t.replacingOccurrences(of: "{z}", with: "1").replacingOccurrences(of: "{x}", with: "1")
            .replacingOccurrences(of: "{y}", with: "1").replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        if let raw = URL(string: filled)?.host, let h = normalized(raw), !out.contains(h) { out.append(h) }
        return out
    }

    /// The template's tiles come from an OSMF server (any reading of its host is an OSMF host).
    public static func isOpenStreetMapFoundation(template: String) -> Bool {
        hosts(template: template).contains(where: isOpenStreetMapFoundation(host:))
    }

    /// The route-corridor prefetch may run for this template: only a tile server the rider configured,
    /// never an OSMF host (no prefetch, offline or bulk downloads there) and never a template whose host
    /// cannot be read (fail closed).
    public static func allowsCorridorPrefetch(template: String) -> Bool {
        let hosts = hosts(template: template)
        return !hosts.isEmpty && !hosts.contains(where: isOpenStreetMapFoundation(host:))
    }

    /// The credit for the dash map: "© OpenStreetMap" for tiles from the OSMF servers, nil otherwise
    /// (custom servers: no label).
    public static func attribution(template: String) -> String? {
        isOpenStreetMapFoundation(template: template) ? openStreetMapCredit : nil
    }

    // MARK: - Parsing

    /// Host of `scheme://[userinfo@]host[:port][/?#…]`, RFC 3986 delimiters only (a backslash is NOT one,
    /// like Foundation), braces dropped, normalized.
    private static func rfcHost(_ s: String) -> String? {
        guard let sep = s.range(of: "://"), !s[..<sep.lowerBound].isEmpty else { return nil }
        var authority = s[sep.upperBound...]
        if let end = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = authority[..<end]
        }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        var host = String(authority).replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        if host.hasPrefix("[") {
            if let close = host.firstIndex(of: "]") { host = String(host[...close]) } // IPv6 literal, port dropped
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        return normalized(host)
    }

    /// Percent-decoded, lower-cased, without a port or trailing dots; nil when empty.
    private static func normalized(_ raw: String) -> String? {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        h = (h.removingPercentEncoding ?? h).lowercased()
        if !h.hasPrefix("["), let colon = h.lastIndex(of: ":"), h[h.index(after: colon)...].allSatisfy(\.isNumber) {
            h = String(h[..<colon])
        }
        while h.hasSuffix(".") { h.removeLast() }
        return h.isEmpty ? nil : h
    }
}
