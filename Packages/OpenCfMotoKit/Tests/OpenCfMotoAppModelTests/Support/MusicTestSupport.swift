// SPDX-License-Identifier: AGPL-3.0-or-later
// Apple Music on the dash — test doubles shared by the music tests: a manual clock, the fixture
// songs (fictional; the demo queue of the contract), a Music port that reports exactly the readings
// a test scripts (any MPMusicPlaybackState, artwork that may suspend), a sleeper the test ends by
// hand (the F1 grace) and a rig around MusicModel.
// NOTE (Linux): main-actor tests must be `async` (swift-corelibs-xctest).

import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

/// Monotonic clock moved by hand (thread-safe: the render-side display list reads it too).
final class MusicTestClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ start: TimeInterval = 1_000) { value = start }

    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

enum MusicFixtures {
    static let ruta = MusicTrack(id: "p1a", title: "Ruta del Sol (Remastered 2012)", artist: "Los Pistones",
                                 album: "Ruta Sessions", duration: 364)
    static let pass = MusicTrack(id: "s100000002", title: "Mountain Pass", artist: "Gearshift", album: "Twisties",
                                 duration: 245, storeID: "100000002")
    static let night = MusicTrack(id: "p3c", title: "Night Ride Home", artist: "Asphalt Echo", album: "Open Throttle",
                                  duration: 318)
    static let queue = [ruta, pass, night]
    /// Every title / artist / album and store id above: none may ever reach a log line (F4: a catalog
    /// id names the song on music.apple.com).
    static let privateWords = ["Ruta del Sol", "Los Pistones", "Ruta Sessions", "Mountain Pass", "Gearshift",
                               "Twisties", "Night Ride Home", "Asphalt Echo", "Open Throttle", "100000002"]
    /// The track ids above: a log line carries their keyed tokens only (F4). Short, so they are
    /// checked as whole words (a token "p1a…" is one word with more hex digits).
    static let privateIDs = ["p1a", "s100000002", "p3c"]

    /// A minimal PNG-looking payload (MusicModel never decodes it; the renderer side would).
    static func art(_ tag: UInt8, _ source: MusicArtworkSource = .mediaItem) -> MusicArtwork {
        MusicArtwork(data: Data([0x89, 0x50, 0x4E, 0x47, tag]), source: source)
    }

    static func reading(_ track: MusicTrack?, _ state: MusicPlaybackState, position: TimeInterval = 0,
                        at t: TimeInterval = 1_000, other: Bool = false) -> MusicSnapshot {
        MusicSnapshot(track: track, state: state, position: position, sampledAt: t,
                      rate: state == .playing ? 1 : 0, otherAudioPlaying: other)
    }
}

/// A Music port that reports exactly what the test scripts.
@MainActor
final class ScriptedMusic: MusicPlaying {
    var isAvailable = true
    var authorization: MusicAuthorizationState = .authorized
    private(set) var snapshot: MusicSnapshot = .empty
    var onChange: ((MusicSnapshot) -> Void)?
    private(set) var isObserving = false
    /// What the player holds (reported when observing starts and by `emit`).
    var pending: MusicSnapshot = .empty
    /// `artwork(trackID:maxPixelSize:)` answers with this (it may suspend); nil handler = no artwork.
    var artworkHandler: ((String) async -> MusicArtwork?)?
    private(set) var artworkRequests: [String] = []
    private(set) var commands: [String] = []
    private(set) var refreshes = 0

    init() {}

    func requestAuthorization() async -> MusicAuthorizationState { authorization }

    func startObserving() {
        guard authorization == .authorized, !isObserving else { return }
        isObserving = true
        report(pending)
    }

    func stopObserving() {
        isObserving = false
        snapshot = .empty
    }

    func refresh() { refreshes += 1 }

    /// The Music app changed (reported while observing).
    func emit(_ reading: MusicSnapshot) {
        pending = reading
        report(reading)
    }

    func artwork(trackID: String, maxPixelSize: Int) async -> MusicArtwork? {
        artworkRequests.append(trackID)
        guard let handler = artworkHandler else { return nil }
        return await handler(trackID)
    }

    func play() { commands.append("play") }
    func pause() { commands.append("pause") }
    func skipToNext() { commands.append("next") }
    func skipToPrevious() { commands.append("previous") }
    func skipToBeginning() { commands.append("beginning") }

    private func report(_ reading: MusicSnapshot) {
        guard isObserving, reading != snapshot else { return }
        snapshot = reading
        onChange?(reading)
    }
}

/// Waits that end when the test says so (`endWaits()`), never by wall time — the F1 grace. A
/// cancelled wait returns at once (the waiting task then sees `Task.isCancelled`).
@MainActor
final class ManualSleeper {
    /// Every wait asked for, in seconds.
    private(set) var requests: [TimeInterval] = []
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0
    /// Waits not ended yet.
    var pendingCount: Int { waiting.count }

    func sleep(_ seconds: TimeInterval) async {
        requests.append(seconds)
        let id = nextID
        nextID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiting[id] = $0 }
        } onCancel: {
            Task { @MainActor in self.end(id) }
        }
    }

    /// Ends every pending wait (moving the clock is the test's business).
    func endWaits() {
        for id in waiting.keys.sorted() { end(id) }
    }

    private func end(_ id: Int) {
        waiting.removeValue(forKey: id)?.resume()
    }
}

/// A suspended `artwork` call the test resumes later (stale-result tests).
@MainActor
final class ArtworkGate {
    private var continuation: CheckedContinuation<MusicArtwork?, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async -> MusicArtwork? {
        await withCheckedContinuation { continuation = $0 }
    }

    func open(with artwork: MusicArtwork?) {
        continuation?.resume(returning: artwork)
        continuation = nil
    }
}

/// MusicModel over the preview services: manual clock, recorded sleeps (returning at once and
/// moving the clock), recorded dash publications and hand-over callbacks.
@MainActor
final class MusicRig {
    let clock = MusicTestClock()
    let projection = PreviewProjection()
    let system = PreviewSystem()
    let services: AppServices
    let model: MusicModel
    /// Every wait the model asked for (artwork retries, re-reads after commands).
    var sleeps: [TimeInterval] = []
    /// The F1 grace waits (ended by the test: `endGrace`).
    let grace = ManualSleeper()
    var started = 0
    var paused = 0
    /// At every `onDashChange`: the artwork id the dash would show, the images registered then and
    /// whether the dash shows the song at all.
    var publications: [(artworkId: String?, registered: Set<String>, calls: Int, shown: Bool)] = []

    init(enabled: Bool = true, port makePort: (MonotonicClock) -> MusicPlaying) {
        var services = AppServices.preview(clock: clock)
        services.projection = projection
        services.system = system
        services.music = makePort(clock)
        if enabled { services.keyValueStore.set(true, forKey: MusicModel.enabledKey) }
        self.services = services
        model = MusicModel(core: AppCore(services: services))
        model.imageCleanupDelay = 0
        let clock = self.clock
        model.sleeper = { [weak self] seconds in
            self?.sleeps.append(seconds)
            clock.advance(seconds)
        }
        let grace = self.grace
        model.graceSleeper = { seconds in await grace.sleep(seconds) }
        model.onDashChange = { [weak self] in
            guard let self else { return }
            self.publications.append((self.model.dashNowPlaying?.artworkId, Set(self.projection.dashImages.keys),
                                      self.projection.dashImageCalls.count, self.model.dashNowPlaying != nil))
        }
        model.onPlaybackStarted = { [weak self] in self?.started += 1 }
        model.onPlaybackPaused = { [weak self] in self?.paused += 1 }
    }

    var preview: PreviewMusic {
        guard let p = services.music as? PreviewMusic else { fatalError("not a PreviewMusic rig") }
        return p
    }

    var scripted: ScriptedMusic {
        guard let p = services.music as? ScriptedMusic else { fatalError("not a ScriptedMusic rig") }
        return p
    }

    /// The renderer-side calls as comparable pairs.
    var imageCalls: [String] { projection.dashImageCalls.map { "\($0.registered ? "+" : "-")\($0.id)" } }

    /// F1: `seconds` pass and the grace wait ends; true once the model re-evaluated (published). The
    /// waits are ended until then: the waiting task may not have reached its wait yet.
    func endGrace(after seconds: TimeInterval) async -> Bool {
        let before = publications.count
        clock.advance(seconds)
        return await eventually {
            self.grace.endWaits()
            return self.publications.count > before
        }
    }
}

/// Collects every log line written while it is alive (privacy checks).
final class LogCapture: @unchecked Sendable {
    private let lines = Locked<[LogLine]>([])
    private var token: UUID?

    init() {
        token = Log.shared.subscribe { [lines] line in lines.withLock { $0.append(line) } }
    }

    deinit { stop() }

    func stop() {
        if let token { Log.shared.unsubscribe(token) }
        token = nil
    }

    var all: [LogLine] { lines.current }
    func messages(tag: String) -> [String] { all.filter { $0.tag == tag }.map(\.message) }
}
