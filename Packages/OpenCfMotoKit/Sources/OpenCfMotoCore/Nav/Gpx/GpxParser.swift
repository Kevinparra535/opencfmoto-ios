// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxParser.kt, GpxActivity.kt (import validation)
//
// Android parses GPX with regexes (self-closing points end up after all long-form points and can
// be swallowed). Here `XMLParser` reads the document in order (docs/spec/navigation-dash.md §3.1):
// `trkpt` → track, `rtept` → route, `wpt` → waypoints; points need numeric `lat` and `lon`;
// optional `<ele>` and trimmed `<name>`. Name = first `<trk>` name, else first `<rte>` name,
// else the file name without extension. Points = track points if any, else route points.
// Element / attribute names are matched case-insensitively and namespace prefixes are ignored.

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum GpxParser {
    /// Parses GPX bytes. Never throws: malformed XML yields whatever was read before the error.
    public static func parse(_ data: Data, fallbackName: String = "") -> GpxTrack {
        let delegate = GpxXMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        let points = !delegate.trackPoints.isEmpty ? delegate.trackPoints : delegate.routePoints
        let name = delegate.trackName ?? delegate.routeName ?? fallbackName
        return GpxTrack(name: name, points: points, waypoints: delegate.waypoints)
    }

    /// Parses a GPX string.
    public static func parse(_ xml: String, fallbackName: String = "") -> GpxTrack {
        parse(Data(xml.utf8), fallbackName: fallbackName)
    }

    /// Reads and parses a file; the fallback name is the file name without extension.
    public static func parse(fileURL: URL) throws -> GpxTrack {
        let data = try Data(contentsOf: fileURL)
        return parse(data, fallbackName: fileURL.deletingPathExtension().lastPathComponent)
    }

    // MARK: Import (Map hub)

    public enum ImportError: Error, Equatable, CustomStringConvertible, LocalizedError {
        case empty
        public var description: String { "GPX has no track points or waypoints" }
        public var errorDescription: String? { description }
    }

    /// Validated import (`GpxActivity.kt:68-122`): rejects files without points and waypoints and
    /// uses the file name when the track has no name.
    public static func importTrack(_ data: Data, fileName: String) throws -> GpxTrack {
        let base = (fileName as NSString).deletingPathExtension
        var track = parse(data, fallbackName: base)
        if track.points.isEmpty && track.waypoints.isEmpty { throw ImportError.empty }
        if track.name.isNavBlank { track.name = base }
        return track
    }

    /// Hub label `"<name>  ·  <N> pts · <M> wpt · <distance>"`.
    public static func summaryLabel(_ track: GpxTrack, units: MapUnits = .metric, decimalSeparator: Character = ".") -> String {
        let dist = NavFormat.formatDistance(GeoMath.pathLength(track.points), units: units, decimalSeparator: decimalSeparator)
        return "\(track.name)  ·  \(track.points.count) pts · \(track.waypoints.count) wpt · \(dist)"
    }

    /// History entry pushed on import: `Place(name, firstPt, "gpx", "GPX track")`.
    public static func historyPlace(_ track: GpxTrack) -> Place? {
        guard let first = track.points.first ?? track.waypoints.first else { return nil }
        return Place(name: track.name, lat: first.lat, lon: first.lon, category: "gpx", subtitle: "GPX track")
    }
}

/// SAX delegate collecting points in document order.
private final class GpxXMLDelegate: NSObject, XMLParserDelegate {
    var trackPoints: [TrackPoint] = []
    var routePoints: [TrackPoint] = []
    var waypoints: [TrackPoint] = []
    var trackName: String?
    var routeName: String?

    private enum PointKind { case trk, rte, wpt }

    private var stack: [String] = []
    // Current point being built.
    private var pointKind: PointKind?
    private var pointDepth = 0
    private var pointLat: Double?
    private var pointLon: Double?
    private var pointEle: Double?
    private var pointName: String?
    private var pointValid = false
    // First <trk> / <rte> container (for the track name).
    private var trkDepth: Int?
    private var rteDepth: Int?
    private var seenTrk = false
    private var seenRte = false
    // Text capture.
    private enum Capture { case pointEle, pointName, trkName, rteName }
    private var capture: Capture?
    private var captureDepth = 0
    private var text = ""

    private static func local(_ name: String) -> String {
        let lower = name.lowercased()
        if let colon = lower.lastIndex(of: ":") { return String(lower[lower.index(after: colon)...]) }
        return lower
    }

    private static func attr(_ attrs: [String: String], _ key: String) -> String? {
        for (k, v) in attrs where local(k) == key { return v }
        return nil
    }

    private static func number(_ s: String?) -> Double? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return Double(t)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = Self.local(elementName)
        stack.append(name)
        let depth = stack.count
        switch name {
        case "trkpt", "rtept", "wpt":
            if pointKind == nil {
                pointKind = name == "trkpt" ? .trk : (name == "rtept" ? .rte : .wpt)
                pointDepth = depth
                pointLat = Self.number(Self.attr(attributeDict, "lat"))
                pointLon = Self.number(Self.attr(attributeDict, "lon"))
                pointValid = pointLat != nil && pointLon != nil
                pointEle = nil
                pointName = nil
            }
        case "trk":
            if !seenTrk { seenTrk = true; trkDepth = depth }
        case "rte":
            if !seenRte { seenRte = true; rteDepth = depth }
        case "ele":
            if pointKind != nil && depth == pointDepth + 1 && pointEle == nil && capture == nil {
                capture = .pointEle; captureDepth = depth; text = ""
            }
        case "name":
            if capture != nil { break }
            if pointKind != nil {
                if depth == pointDepth + 1 && pointName == nil { capture = .pointName; captureDepth = depth; text = "" }
            } else if let d = trkDepth, depth == d + 1, trackName == nil {
                capture = .trkName; captureDepth = depth; text = ""
            } else if let d = rteDepth, depth == d + 1, routeName == nil {
                capture = .rteName; captureDepth = depth; text = ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capture != nil { text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let depth = stack.count
        if let c = capture, depth == captureDepth {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch c {
            case .pointEle: pointEle = Self.number(value)
            case .pointName: if !value.isEmpty { pointName = value }
            case .trkName: if !value.isEmpty { trackName = value }
            case .rteName: if !value.isEmpty { routeName = value }
            }
            capture = nil
            text = ""
        }
        if let kind = pointKind, depth == pointDepth {
            if pointValid, let lat = pointLat, let lon = pointLon {
                let p = TrackPoint(lat: lat, lon: lon, ele: pointEle, name: pointName)
                switch kind {
                case .trk: trackPoints.append(p)
                case .rte: routePoints.append(p)
                case .wpt: waypoints.append(p)
                }
            }
            pointKind = nil
        }
        if let d = trkDepth, depth == d { trkDepth = nil }
        if let d = rteDepth, depth == d { rteDepth = nil }
        if !stack.isEmpty { stack.removeLast() }
    }
}
