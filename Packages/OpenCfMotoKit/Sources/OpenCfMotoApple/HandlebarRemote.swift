// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MediaButtonBridge.kt (MediaSession "OpenCfMoto", permanent
// PLAYING state, 1 s silent PCM loop at volume 0.01, transport keys → select/forward/backward
// channels, absolute-volume ▲/▼ observation).
//
// Captures the motorcycle's handlebar buttons (Bluetooth AVRCP) on iOS. docs/spec/input-controls.md
// §8–§10 and ios-platform-facts.md (g):
// - iOS delivers AVRCP transport keys as MPRemoteCommands ONLY to the "Now Playing" app, which needs
//   a NON-MIXABLE `.playback` session that is actually playing. This adapter therefore plays a
//   generated silent PCM loop (volume 0.01) while — and only while — capture is enabled.
// - Consequence: enabling capture INTERRUPTS the rider's music (Spotify etc. pause), and if the rider
//   starts music again that app becomes Now Playing and receives the keys. We do NOT auto-reclaim
//   while `isOtherAudioPlaying`; we re-claim when an interruption ends. While we are not claimed,
//   voice prompts use SpeechAnnouncer's own mixable session (`captureOwnsSession` is
//   `isEnabled && isClaimed`), so they duck the rider's music instead of pausing it.
// - Events are raw (`HandlebarRawEvent` + monotonic time); tap / double / hold detection is done by
//   `HandlebarGestureEngine` in OpenCfMotoCore.
//
// APP REVIEW RISK (document in the review notes):
// - 2.5.4 "background services for their intended purposes": a silent audio loop that keeps the
//   app as Now Playing is the classic rejection ("unable to play any audible content"). Ship it only
//   as an explicit, user-enabled "Capture handlebar buttons" mode tied to audible voice prompts.
// - 2.5.9 "alter or disable standard switches (Volume Up/Down)": the experimental ▲/▼ path only
//   OBSERVES `outputVolume`; it never re-pins the volume (no MPVolumeView slider hack). Off by default.

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore

/// One raw handlebar event as observed on iOS.
public struct HandlebarRemoteEvent: Sendable, Equatable {
    public var raw: HandlebarRawEvent
    /// Monotonic seconds (`MonotonicClock`, ProcessInfo.systemUptime) when it was received.
    public var time: TimeInterval
    /// Volume steps for `.volumeUp` / `.volumeDown` (iOS volume has 16 steps); 1 for other events.
    /// Android: a jump of ≥ 3 steps from a fast ▲▲/▼▼ flick counts as a double.
    public var steps: Int

    public init(raw: HandlebarRawEvent, time: TimeInterval, steps: Int = 1) {
        self.raw = raw
        self.time = time
        self.steps = steps
    }
}

/// `outputVolume` deltas → ▲/▼ events (experimental path).
public enum HandlebarVolumeMath {
    /// iOS system volume step (1/16).
    public static let stepSize: Float = 0.0625

    /// nil when the change is smaller than half a step; otherwise direction and rounded step count (≥ 1).
    public static func event(old: Float, new: Float) -> (raw: HandlebarRawEvent, steps: Int)? {
        let delta = new - old
        guard abs(delta) >= stepSize / 2 else { return nil }
        let steps = max(1, Int((abs(delta) / stepSize).rounded()))
        return (delta > 0 ? .volumeUp : .volumeDown, steps)
    }
}

/// In-memory WAV of digital silence (RIFF/WAVE PCM 16-bit little-endian), like Android's 8 kHz
/// mono 1 s AudioTrack buffer.
public enum SilentWAV {
    public static func make(sampleRate: Int = 8000, channels: Int = 1, seconds: Double = 1) -> Data {
        let rate = max(1, sampleRate)
        let ch = max(1, channels)
        let frames = max(1, Int((Double(rate) * seconds).rounded()))
        let dataSize = frames * ch * 2
        var w = ByteWriter(capacity: 44 + dataSize)
        w.append(Array("RIFF".utf8))
        w.u32le(UInt32(36 + dataSize))
        w.append(Array("WAVE".utf8))
        w.append(Array("fmt ".utf8))
        w.u32le(16)                           // PCM fmt chunk size
        w.u16le(1)                            // PCM
        w.u16le(UInt16(ch))
        w.u32le(UInt32(rate))
        w.u32le(UInt32(rate * ch * 2))        // byte rate
        w.u16le(UInt16(ch * 2))               // block align
        w.u16le(16)                           // bits per sample
        w.append(Array("data".utf8))
        w.u32le(UInt32(dataSize))
        w.zeros(dataSize)
        return w.data
    }
}

/// Thread-safe fan-out of handlebar events (callback + AsyncStreams). Safe to call from any thread
/// (remote-command handlers, KVO).
final class HandlebarEventEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (HandlebarRemoteEvent) -> Void)?
    private let broadcaster = OCMPlatformBroadcaster<HandlebarRemoteEvent>()
    private let clock: any MonotonicClock

    init(clock: any MonotonicClock) {
        self.clock = clock
    }

    var onEvent: (@Sendable (HandlebarRemoteEvent) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); callback = newValue; lock.unlock() }
    }

    func stream() -> AsyncStream<HandlebarRemoteEvent> { broadcaster.stream(buffer: 64) }

    @discardableResult
    func emit(_ raw: HandlebarRawEvent, steps: Int = 1) -> HandlebarRemoteEvent {
        let e = HandlebarRemoteEvent(raw: raw, time: clock.now(), steps: steps)
        Log.i("BTN", "[BTN] remote \(raw.rawValue)" + (steps > 1 ? " ×\(steps)" : ""))
        let cb = onEvent
        cb?(e)
        broadcaster.yield(e)
        return e
    }
}

/// What the dash's AVRCP "now playing" widget shows (Android: title/artist/album, 1 h duration).
/// ASCII only: the dash draws the text in its own font, which showed ◀ ▶ as empty boxes (field test 2,
/// 450MT: "OpenCfMoto ▯ ▯ mov"; ★ and · never caught on camera). The pill scrolls title + artist (another
/// photo shows "oup" of "Group"): most-used keys first.
public struct HandlebarNowPlayingMetadata: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var durationSeconds: Double

    public init(title: String = "OpenCfMoto", artist: String = "< > move  * OK  ** Back  >> Menu  << Group",
                album: String = "OpenCfMoto", durationSeconds: Double = 3600) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
    }
}
#endif

#if canImport(MediaPlayer) && canImport(AVFoundation) && os(iOS)
import AVFoundation
import MediaPlayer

/// Opt-in handlebar capture through MPRemoteCommandCenter (see the file header for the App Review
/// caveats). Main-actor isolated; call `enable()` from the foreground and `disable()` before
/// releasing the object (remote-command targets are process-wide). If `enable()` throws (e.g. the
/// session could not be activated), capture stays enabled and `reclaim()` can retry later.
///
/// Mapping: play / pause / togglePlayPause → `.select`; nextTrack / skipForward → `.forward`;
/// previousTrack / skipBackward → `.backward`; seekForward / seekBackward begin/end → hold events;
/// optional `outputVolume` KVO → `.volumeUp` / `.volumeDown` (experimental, off by default).
@MainActor
public final class HandlebarRemote {
    /// What the dash's AVRCP "now playing" widget shows (ASCII only, see the type).
    public typealias NowPlayingMetadata = HandlebarNowPlayingMetadata

    /// Capture mode is on (the user opted in).
    public private(set) var isEnabled = false {
        didSet { publishSessionOwnership() }
    }
    /// We currently hold the non-mixable session and the silent loop is playing (Now Playing).
    public private(set) var isClaimed = false {
        didSet { publishSessionOwnership() }
    }

    /// Experimental ▲/▼: observe `AVAudioSession.outputVolume` while capturing. Off by default; it
    /// never changes the volume back (no re-pinning), so presses really change the rider's volume.
    public var volumeButtonsEnabled = false {
        didSet { updateVolumeObservation() }
    }

    public var metadata = NowPlayingMetadata() {
        didSet { if isClaimed { publishNowPlaying() } }
    }

    /// Called for every raw event, on the thread that delivered it (remote-command handlers usually
    /// run on the main thread; volume KVO on an arbitrary thread) — hop to your own actor if needed.
    public var onEvent: (@Sendable (HandlebarRemoteEvent) -> Void)? {
        get { emitter.onEvent }
        set { emitter.onEvent = newValue }
    }

    private let emitter: HandlebarEventEmitter
    private var player: AVAudioPlayer?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []
    private var volumeObservation: NSKeyValueObservation?

    public init(clock: any MonotonicClock = SystemMonotonicClock()) {
        self.emitter = HandlebarEventEmitter(clock: clock)
    }

    /// Stream of raw events (independent per call).
    public func events() -> AsyncStream<HandlebarRemoteEvent> { emitter.stream() }

    /// Turns capture on: registers the remote commands, activates a non-mixable `.playback` session,
    /// starts the silent loop and publishes Now Playing info. Pauses other apps' audio.
    public func enable() throws {
        guard !isEnabled else { return }
        isEnabled = true
        registerCommands()
        startObservers()
        do {
            try claim()
        } catch {
            Log.w("BTN", "[BTN] could not become Now Playing: \(error.localizedDescription)")
            throw error
        }
        updateVolumeObservation()
        Log.i("BTN", "[BTN] handlebar capture ON")
    }

    /// Turns capture off and releases the session (other apps may resume their audio).
    public func disable() {
        guard isEnabled else { return }
        isEnabled = false
        volumeObservation?.invalidate()
        volumeObservation = nil
        unregisterCommands()
        stopObservers()
        player?.stop()
        player = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if isClaimed {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        isClaimed = false
        Log.i("BTN", "[BTN] handlebar capture OFF")
    }

    /// Re-claims Now Playing (e.g. when the app returns to the foreground). Returns false — and does
    /// nothing — while another app is playing audio (that would pause the rider's music).
    @discardableResult
    public func reclaim() -> Bool {
        guard isEnabled else { return false }
        if AVAudioSession.sharedInstance().isOtherAudioPlaying {
            Log.i("BTN", "[BTN] other audio is playing — not reclaiming the handlebar buttons")
            return false
        }
        do {
            try claim()
            return true
        } catch {
            Log.w("BTN", "[BTN] reclaim failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Session / silent loop

    /// The silent loop refused to start, so we are not Now Playing.
    private struct SilentLoopDidNotStart: LocalizedError {
        var errorDescription: String? { "the silent Now Playing loop did not start" }
    }

    /// Becomes Now Playing. `isClaimed` (and with it the coordinator's `captureOwnsSession`) turns true
    /// only once the non-mixable session is active AND the loop plays; on any failure the session is
    /// released again, so a half-claimed non-mixable session never silences the rider's music.
    private func claim() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])   // non-mixable
        try session.setActive(true)
        do {
            if player == nil {
                let p = try AVAudioPlayer(data: SilentWAV.make(), fileTypeHint: AVFileType.wav.rawValue)
                p.numberOfLoops = -1
                p.volume = 0.01
                p.prepareToPlay()
                player = p
            }
            guard player?.play() == true else { throw SilentLoopDidNotStart() }
        } catch {
            player?.stop()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        isClaimed = true
        publishNowPlaying()
    }

    /// Voice prompts speak inside our session only while we really hold it (enabled AND claimed).
    /// After another app took the session (interruption), while a reclaim is declined because other
    /// audio plays, or after a failed claim, `SpeechAnnouncer` uses its own transient MIXABLE
    /// `.voicePrompt` session again — otherwise every prompt would implicitly re-activate our
    /// non-mixable category (pausing the rider's music for good in the foreground, or failing with
    /// `cannotInterruptOthers` while locked so the prompt is never heard). Review finding IOS-1.
    private func publishSessionOwnership() {
        OCMAudioSessionCoordinator.shared.captureOwnsSession = isEnabled && isClaimed
    }

    private func publishNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: metadata.title,
            MPMediaItemPropertyArtist: metadata.artist,
            MPMediaItemPropertyAlbumTitle: metadata.album,
            MPMediaItemPropertyPlaybackDuration: metadata.durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
    }

    // MARK: Remote commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        let e = emitter
        func add(_ command: MPRemoteCommand, _ raw: HandlebarRawEvent) {
            command.isEnabled = true
            commandTargets.append((command, command.addTarget(handler: Self.tapHandler(e, raw))))
        }
        add(center.playCommand, .select)
        add(center.pauseCommand, .select)
        add(center.togglePlayPauseCommand, .select)
        add(center.nextTrackCommand, .forward)
        add(center.skipForwardCommand, .forward)
        add(center.previousTrackCommand, .backward)
        add(center.skipBackwardCommand, .backward)
        center.seekForwardCommand.isEnabled = true
        commandTargets.append((center.seekForwardCommand,
                               center.seekForwardCommand.addTarget(handler: Self.seekHandler(e, began: .forwardHoldBegan, ended: .forwardHoldEnded))))
        center.seekBackwardCommand.isEnabled = true
        commandTargets.append((center.seekBackwardCommand,
                               center.seekBackwardCommand.addTarget(handler: Self.seekHandler(e, began: .backwardHoldBegan, ended: .backwardHoldEnded))))
        center.changePlaybackPositionCommand.isEnabled = false
        center.stopCommand.isEnabled = false
    }

    private func unregisterCommands() {
        for (command, target) in commandTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        commandTargets.removeAll()
    }

    nonisolated private static func tapHandler(_ emitter: HandlebarEventEmitter, _ raw: HandlebarRawEvent)
        -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return { _ in
            emitter.emit(raw)
            return .success
        }
    }

    nonisolated private static func seekHandler(_ emitter: HandlebarEventEmitter, began: HandlebarRawEvent,
                                                ended: HandlebarRawEvent) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return { event in
            guard let seek = event as? MPSeekCommandEvent else { return .commandFailed }
            switch seek.type {
            case .beginSeeking: emitter.emit(began)
            case .endSeeking: emitter.emit(ended)
            @unknown default: return .commandFailed
            }
            return .success
        }
    }

    // MARK: Audio session notifications

    private func startObservers() {
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                        queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(raw) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: session,
                                        queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
            MainActor.assumeIsolated { self?.handleSecondaryAudioHint(raw) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleRouteChange() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
    }

    private func stopObservers() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }

    private func handleInterruption(_ raw: UInt?) {
        guard isEnabled, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            isClaimed = false
            Log.i("BTN", "[BTN] audio interrupted — another app is Now Playing")
        case .ended:
            reclaim()
        @unknown default:
            break
        }
    }

    private func handleSecondaryAudioHint(_ raw: UInt?) {
        guard isEnabled, !isClaimed, let raw,
              let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw), type == .end else { return }
        reclaim()
    }

    private func handleRouteChange() {
        guard isEnabled, isClaimed, let p = player, !p.isPlaying else { return }
        p.play()
    }

    private func handleMediaServicesReset() {
        guard isEnabled else { return }
        player = nil
        isClaimed = false
        unregisterCommands()
        registerCommands()
        reclaim()
    }

    // MARK: Experimental volume path

    private func updateVolumeObservation() {
        guard isEnabled, volumeButtonsEnabled else {
            volumeObservation?.invalidate()
            volumeObservation = nil
            return
        }
        guard volumeObservation == nil else { return }
        let e = emitter
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.old, .new]) { _, change in
            guard let old = change.oldValue, let new = change.newValue,
                  let ev = HandlebarVolumeMath.event(old: old, new: new) else { return }
            e.emit(ev.raw, steps: ev.steps)
        }
    }
}
#endif
