// SPDX-License-Identifier: AGPL-3.0-or-later
// `DashProjecting` on iOS: DashDisplayList → DashRenderer (CoreGraphics, CoreText, raster tiles from
// TileImageCache over the smart HTTP client) → DashProjectionEngine (VideoToolbox H.264, pull-paced,
// hold IDR / software encoder in the background) with ThermalMonitor caps. The same DashRenderer
// draws the phone preview of the dash (AppPlatform.dashRenderer). Album artwork for the Apple Music
// tile / sheet (`DashDrawCommand.image`) comes from `images`, filled by `setDashImage(id:data:)`.

import Foundation
import OpenCfMotoCore
import OpenCfMotoApple
import OpenCfMotoAppModel

final class ProjectionAdapter: DashProjecting, @unchecked Sendable {
    let engine: DashProjectionEngine
    let renderer: DashRenderer
    let tiles: TileImageCache
    /// Raster images of the dash UI (Apple Music artwork), shared with the phone preview.
    let images = DashImageStore()
    let textMeasurer: DashTextMeasurer = CoreTextMeasurer()
    private let thermal: ThermalMonitor
    private let lock = NSLock()
    private var tileLoaded: (@Sendable () -> Void)?

    /// Corridor prefetch zooms / radius (the bike follow camera sits around z15.4–18.6; the tile
    /// cache caps one prefetch at 400 tiles — OSM tile usage policy).
    private static let corridorZooms = 14 ... 17
    private static let corridorRadiusMeters = 250.0

    init(http: HTTPClient, tileURLTemplate: String, clock: MonotonicClock) {
        tiles = TileImageCache(httpClient: http, configuration: TileImageCache.Configuration(urlTemplate: tileURLTemplate))
        renderer = DashRenderer(tileCache: tiles, imageStore: images)
        engine = DashProjectionEngine(renderer: renderer, clock: clock)
        thermal = ThermalMonitor()
        thermal.start()
        engine.attach(thermalMonitor: thermal)
        tiles.onTileLoaded = { [weak self] _ in
            guard let self else { return }
            self.engine.invalidate()
            self.onTileLoaded?()
        }
    }

    var frameSource: VideoFrameSource { engine }

    var stats: ProjectionStatsSummary { Self.summary(engine.stats) }

    var onTileLoaded: (@Sendable () -> Void)? {
        get { lock.withLock { tileLoaded } }
        set { lock.withLock { tileLoaded = newValue } }
    }

    var onCanvasPrepared: (@Sendable (VideoCanvas) -> Void)? {
        get { engine.onPrepared }
        set { engine.onPrepared = newValue }
    }

    func setDisplayListProvider(_ provider: (@Sendable (TimeInterval) -> DashDisplayList)?) {
        engine.displayListProvider = provider
    }

    func setHoldDisplayListProvider(_ provider: (@Sendable (TimeInterval) -> DashDisplayList)?) {
        engine.holdDisplayListProvider = provider
    }

    func setEncoderParameters(_ parameters: EncoderParameters) {
        engine.parameters = parameters
    }

    func setThermalCapsEnabled(_ enabled: Bool) {
        engine.appliesThermalCaps = enabled
    }

    func invalidate() { engine.invalidate() }
    func prepareHoldPicture() { engine.prepareHoldPicture() }
    func prepareHoldPicture(expectedCanvas: VideoCanvas) { engine.prepareHoldPicture(expectedCanvas: expectedCanvas) }
    func startWireDump(to url: URL, maxFrames: Int) throws { try engine.startWireDump(to: url, maxFrames: maxFrames) }
    func stopWireDump() { engine.stopWireDump() }
    func enterBackground() { engine.enterBackground() }
    func enterForeground() { engine.enterForeground() }
    func stop() { engine.stop() }

    func requestTiles(_ tiles: [DashMapTile]) {
        for t in tiles { self.tiles.request(z: t.z, x: t.x, y: t.y) }
    }

    func prefetchCorridor(_ points: [GeoPoint]) {
        guard points.count >= 2 else { return }
        tiles.prefetch(corridor: points, zooms: Self.corridorZooms, radiusMeters: Self.corridorRadiusMeters)
    }

    func setTileURLTemplate(_ template: String) {
        tiles.urlTemplate = template
    }

    func clearTileCache() {
        tiles.clearDisk()
    }

    func setDashImage(id: String, data: Data?) {
        if let data {
            if !images.set(id: id, data: data) {
                Log.w("MUSIC", "artwork bytes rejected id=\(id)")
            }
        } else {
            images.remove(id: id)
        }
        engine.invalidate()
    }

    private static func summary(_ s: DashProjectionStats) -> ProjectionStatsSummary {
        let mode: String
        switch s.mode {
        case .idle: mode = "idle"
        case .foreground: mode = "foreground"
        case .backgroundSoftware: mode = "background-software"
        case .hold: mode = "hold"
        case .stopped: mode = "stopped"
        }
        return ProjectionStatsSummary(mode: mode, renderedFrames: s.renderedFrames, encodedFrames: s.outputFrames,
                                      framesPerSecond: s.outputFPS, bitrate: s.effectiveParameters.bitrate,
                                      lastError: s.encoderErrors > 0 ? "encoder errors: \(s.encoderErrors)" : nil)
    }
}
