// SPDX-License-Identifier: AGPL-3.0-or-later
// `MusicPlaying` on iOS (Apple Music on the dash, scratchpad contract "music" §2.1, §8.5): the system
// Music app through MediaPlayer's `MPMusicPlayerController.systemMusicPlayer` — song, state,
// position and the transport controls — plus the song's artwork: the media item's own picture
// (local, no network) or, for streamed songs without one, MusicKit's artwork of the playing entry
// (loaded by Apple's own URL handling through `URLSession.shared`; no iTunes / catalog API) — only
// when that entry is the same song by title, artist and catalog id, before and after the download
// (review fix F5: the two players update independently).
//
// Lives in the APP target, never in OpenCfMotoApple: the ReplayKit extension links that package
// and App Store Connect checks NSAppleMusicUsageDescription bundle by bundle (ITMS-90683;
// tools/testflight/lint_bundle.py guards it). Nothing touches the system player or MusicKit before
// the media-library permission is `.authorized` (no prompt can appear during a ride; a missing
// purpose string would terminate the app). MusicKit's permission is only READ, never requested.
//
// Change events: MediaPlayer's two notifications (song / state) + a re-sync poll (2 s in the
// foreground, 5 s in the background — the app keeps running there for the ride's location
// updates) + a settle read 0.6 s after a song or state change (late metadata, `isOtherAudioPlaying`
// right after a pause). `onChange` fires only for meaningful changes (MusicSnapshot.differsMeaningfully),
// never for the steady advance of the position: the dash extrapolates it.
// Privacy: titles, artists, albums, track / store ids and artwork URLs are never logged (F4).

import AVFoundation
import Foundation
import ImageIO
import MediaPlayer
import MusicKit
import UIKit
import OpenCfMotoCore
import OpenCfMotoAppModel

@MainActor
final class MusicAdapter: MusicPlaying {
    /// Kill switch of the MusicKit artwork fallback (the media item's own artwork always comes first).
    static let usesMusicKitArtwork = true
    /// The MusicKit artwork download gives up after this long.
    static let artworkTimeout: TimeInterval = 10
    static let jpegQuality: CGFloat = 0.85

    private let clock: MonotonicClock
    private(set) var snapshot: MusicSnapshot = .empty
    var onChange: ((MusicSnapshot) -> Void)?

    private var observedPlayer: MPMusicPlayerController?
    private var observers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var isForeground = true

    init(clock: MonotonicClock) {
        self.clock = clock
    }

    // MARK: - Permission

    /// The Simulator has no music library (the demo / E2E modes use `PreviewMusic` instead).
    var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    var authorization: MusicAuthorizationState {
        guard isAvailable else { return .unavailable }
        return Self.map(MPMediaLibrary.authorizationStatus())
    }

    func requestAuthorization() async -> MusicAuthorizationState {
        guard isAvailable else { return .unavailable }
        guard MPMediaLibrary.authorizationStatus() == .notDetermined else { return authorization }
        let status: MPMediaLibraryAuthorizationStatus = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        return Self.map(status)
    }

    /// The system player, only once the rider allowed "Media & Apple Music".
    private var player: MPMusicPlayerController? {
        guard isAvailable, MPMediaLibrary.authorizationStatus() == .authorized else { return nil }
        return MPMusicPlayerController.systemMusicPlayer
    }

    // MARK: - Following the Music app

    func startObserving() {
        guard observedPlayer == nil, let player else { return }
        observedPlayer = player
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.read() }
            },
            center.addObserver(forName: .MPMusicPlayerControllerPlaybackStateDidChange, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.read() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isForeground = true
                    self?.read()
                }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isForeground = false }
            },
        ]
        isForeground = UIApplication.shared.applicationState != .background
        startPolling()
        read()
    }

    func stopObserving() {
        settleTask?.cancel()
        settleTask = nil
        pollTask?.cancel()
        pollTask = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
        observedPlayer?.endGeneratingPlaybackNotifications()
        observedPlayer = nil
        snapshot = .empty
    }

    func refresh() {
        read()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval: TimeInterval = (self?.isForeground ?? true) ? 2 : 5
                await sleepSeconds(interval)
                guard !Task.isCancelled, let self else { return }
                self.read()
            }
        }
    }

    /// Reads the player and reports a meaningful change.
    private func read() {
        guard observedPlayer != nil, let player else { return }
        let next = Self.reading(of: player, sampledAt: clock.now(),
                                 otherAudioPlaying: AVAudioSession.sharedInstance().isOtherAudioPlaying)
        guard next.differsMeaningfully(from: snapshot) else { return }
        let songOrState = next.track?.id != snapshot.track?.id || next.state != snapshot.state
        snapshot = next
        onChange?(next)
        if songOrState { scheduleSettleRead() }
    }

    private func scheduleSettleRead() {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            await sleepSeconds(0.6)
            guard !Task.isCancelled else { return }
            self?.read()
        }
    }

    // MARK: - Transport (MusicModel re-reads afterwards)

    func play() { player?.play() }
    func pause() { player?.pause() }
    func skipToNext() { player?.skipToNextItem() }
    func skipToPrevious() { player?.skipToPreviousItem() }
    func skipToBeginning() { player?.skipToBeginning() }

    // MARK: - Artwork

    func artwork(trackID: String, maxPixelSize: Int) async -> MusicArtwork? {
        guard observedPlayer != nil, let item = player?.nowPlayingItem, Self.trackID(of: item) == trackID else { return nil }
        let side = max(1, maxPixelSize)
        // 1. The media item's own picture (library songs; often streamed ones too): local.
        if let picture = item.artwork?.image(at: CGSize(width: side, height: side)),
           let data = Self.jpeg(picture, maxPixelSize: side) {
            return MusicArtwork(data: data, source: .mediaItem)
        }
        // 2. MusicKit's artwork of the playing entry — when it is this song (F5), loaded by Apple from Apple.
        guard Self.usesMusicKitArtwork, MusicAuthorization.currentStatus == .authorized,
              let entry = SystemMusicPlayer.shared.queue.currentEntry, Self.entryMatches(entry, item),
              let url = entry.artwork?.url(width: side, height: side) else { return nil }
        guard let bytes = await Self.download(url) else { return nil }
        // Still the same song after the download? MediaPlayer's item AND MusicKit's entry, read again
        // (F5): the two update independently, and a wrong cover would be cached under this song.
        guard observedPlayer != nil, let now = player?.nowPlayingItem, Self.trackID(of: now) == trackID,
              let entryNow = SystemMusicPlayer.shared.queue.currentEntry, Self.entryMatches(entryNow, now),
              let data = Self.thumbnailJPEG(bytes, maxPixelSize: side) else { return nil }
        return MusicArtwork(data: data, source: .musicKit)
    }

    /// F5: MusicKit's queue entry is MediaPlayer's item (`MusicEntryMatch`: title AND artist, and the
    /// catalog ids when both sides have one — never a library id "i.…" against a catalog one).
    /// (`MusicKit.` because AudioToolbox, through AVFoundation, has a `MusicPlayer` too.)
    static func entryMatches(_ entry: MusicKit.MusicPlayer.Queue.Entry, _ item: MPMediaItem) -> Bool {
        let entryItem: MusicKit.MusicPlayer.Queue.Entry.Item? = entry.item
        var song: MusicKit.Song?
        if case .song(let s)? = entryItem { song = s }
        return MusicEntryMatch.matches(entryTitle: entry.title, entrySubtitle: entry.subtitle,
                                       songArtist: song?.artistName, songID: song?.id.rawValue,
                                       itemTitle: item.title ?? "", itemArtist: item.artist ?? item.albumArtist ?? "",
                                       itemStoreID: item.playbackStoreID)
    }

    /// `URLSession.shared` on purpose: MusicKit's `musicKit://` artwork URLs only load through the
    /// shared session (a custom one reports "unsupported URL"). The default route — cellular while
    /// the phone sits on the dash's Wi-Fi without internet.
    private static func download(_ url: URL) async -> Data? {
        do {
            return try await withTimeout(artworkTimeout, label: "musickit artwork") {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                return data
            }
        } catch {
            let ns = error as NSError
            Log.i("MUSIC", "musickit artwork failed: \(ns.domain)/\(ns.code)")
            return nil
        }
    }

    // MARK: - Mapping (MediaPlayer → port types)

    static func reading(of player: MPMusicPlayerController, sampledAt: TimeInterval,
                         otherAudioPlaying: Bool) -> MusicSnapshot {
        let state = map(player.playbackState)
        let track = player.nowPlayingItem.map { Self.track(of: $0) }
        let raw = player.currentPlaybackTime
        let position = raw.isFinite && raw > 0 ? raw : 0
        var rate = 0.0
        if state == .playing {
            let r = Double(player.currentPlaybackRate)
            rate = r.isFinite && r > 0 ? r : 1 // a playing song never stands still on the dash
        }
        return MusicSnapshot(track: track, state: state, position: position, sampledAt: sampledAt, rate: rate,
                             otherAudioPlaying: otherAudioPlaying)
    }

    /// (`OpenCfMotoAppModel.` because AudioToolbox, through AVFoundation, has a `MusicTrack` too.)
    static func track(of item: MPMediaItem) -> OpenCfMotoAppModel.MusicTrack {
        let title = item.title ?? ""
        let artist = item.artist ?? item.albumArtist ?? ""
        let album = item.albumTitle ?? ""
        let duration = item.playbackDuration
        let storeID = MusicTrackID.normalizedStoreID(item.playbackStoreID)
        let id = MusicTrackID.make(persistentID: item.persistentID, storeID: storeID, title: title, artist: artist,
                                   album: album, duration: duration)
        return OpenCfMotoAppModel.MusicTrack(id: id, title: title, artist: artist, album: album,
                                             duration: duration.isFinite && duration > 0 ? duration : 0,
                                             storeID: storeID)
    }

    static func trackID(of item: MPMediaItem) -> String { track(of: item).id }

    static func map(_ state: MPMusicPlaybackState) -> MusicPlaybackState {
        switch state {
        case .stopped: return .stopped
        case .playing: return .playing
        case .paused: return .paused
        case .interrupted: return .interrupted
        case .seekingForward: return .seekingForward
        case .seekingBackward: return .seekingBackward
        @unknown default: return .paused
        }
    }

    static func map(_ status: MPMediaLibraryAuthorizationStatus) -> MusicAuthorizationState {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    // MARK: - Encoding (JPEG ≤ maxPixelSize)

    /// Downscaled (never upscaled) to a longest side ≤ `maxPixelSize`, JPEG 0.85.
    static func jpeg(_ image: UIImage, maxPixelSize: Int) -> Data? {
        let pw = image.size.width * image.scale, ph = image.size.height * image.scale
        guard pw > 0, ph > 0 else { return nil }
        let k = min(1, CGFloat(maxPixelSize) / max(pw, ph))
        let size = CGSize(width: max(1, (pw * k).rounded()), height: max(1, (ph * k).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.jpegData(compressionQuality: jpegQuality)
    }

    /// Any image bytes (JPEG / PNG / HEIC) → a JPEG thumbnail ≤ `maxPixelSize` (ImageIO, EXIF applied).
    static func thumbnailJPEG(_ data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: jpegQuality)
    }
}
