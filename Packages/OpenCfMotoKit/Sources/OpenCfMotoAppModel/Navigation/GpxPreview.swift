// SPDX-License-Identifier: AGPL-3.0-or-later
// An opened GPX track shown as a preview before it replaces anything (UI/UX P0, UX-17): a GPX file
// opened from Files, AirDrop or Mail, or picked with «Elegir archivo GPX…» in the Map hub, is parsed
// and held as `NavigationModel.pendingGpx`; the Map hub draws it with «Seguir este track» / «Cancelar».
// Nothing changes on the phone or the dash until the rider follows it — a route being navigated is
// never replaced silently.

import Foundation
import OpenCfMotoCore

/// A parsed GPX track waiting for the rider's «Seguir este track» / «Cancelar».
public struct GpxPreview: Sendable, Equatable, Identifiable {
    /// Distinct for every opened file (a newer file replaces the preview).
    public let id: UInt64
    /// The file name as opened ("Loop.gpx").
    public let fileName: String
    /// The validated track (`GpxParser.importTrack`: points or waypoints, a name).
    public let track: GpxTrack
    /// Length along the track points in metres (0 for a waypoints-only file).
    public let lengthMeters: Double

    public init(id: UInt64, fileName: String, track: GpxTrack) {
        self.id = id
        self.fileName = fileName
        self.track = track
        let length = GeoMath.pathLength(track.points)
        lengthMeters = length.isFinite && length > 0 ? length : 0
    }

    /// The name shown on the card and, once followed, on the dash.
    public var name: String { track.name }

    /// What the map draws: the track points, else the waypoints (a waypoints-only file).
    public var outline: [TrackPoint] { track.points.isEmpty ? track.waypoints : track.points }
}
