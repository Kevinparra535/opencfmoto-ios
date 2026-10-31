// SPDX-License-Identifier: AGPL-3.0-or-later
// `VideoFrameSource` that serves REAL H.264 access units from an Annex-B elementary stream file
// (default: tools/fakedash/clips/clip_<w>x<h>.h264 for the negotiated canvas; generated with ffmpeg
// into a cache directory when missing). The file is split into NAL units with
// `OpenCfMotoCore.AnnexB`, grouped into access units and normalised exactly like the production
// encoder output (`AnnexB.accessUnit`: SEI/AUD/filler dropped, SPS+PPS in front of EVERY IDR).
//
// Contract (Video/VideoTypes.swift):
// - prepare(canvas:parameters:) loads the clip for the canvas and closes the keyframe gate.
// - resynchronize() closes the gate: the next frame returned is an IDR (with SPS+PPS).
// - nextFrame(timeout:) never returns a P-frame while the gate is closed, never returns the same
//   P-frame twice in a row (the clip cursor always advances; looping restarts at an IDR) and
//   returns nil only if no clip could be loaded within `timeout`.
// - mediaStopped() closes the gate and stops pacing until the next prepare/resynchronize.

import Foundation
import OpenCfMotoCore

/// One access unit of a clip.
struct ClipAccessUnit: Sendable {
    let data: Data
    let isKeyframe: Bool
}

/// A parsed clip.
struct LoadedClip: Sendable {
    let url: URL
    let units: [ClipAccessUnit]
    let width: Int?
    let height: Int?
    let profileIdc: Int?
    let levelIdc: Int?
    var keyframeIndices: [Int] { units.indices.filter { units[$0].isKeyframe } }
}

enum ClipError: Error, CustomStringConvertible {
    case unreadable(String)
    case noAccessUnits(String)
    case noKeyframe(String)
    case generationFailed(String)
    var description: String {
        switch self {
        case let .unreadable(m): return "clip unreadable: \(m)"
        case let .noAccessUnits(m): return "no access units in \(m)"
        case let .noKeyframe(m): return "no IDR in \(m)"
        case let .generationFailed(m): return "ffmpeg clip generation failed: \(m)"
        }
    }
}

enum ClipLoader {
    /// Parses an Annex-B file into normalised access units.
    static func load(_ url: URL) throws -> LoadedClip {
        guard let raw = try? Data(contentsOf: url) else { throw ClipError.unreadable(url.path) }
        let nals = AnnexB.nalUnits(annexB: raw)
        var units: [ClipAccessUnit] = []
        var sps: [Data] = []
        var pps: [Data] = []
        var current: [Data] = [] // NALs of the AU being built
        var currentHasVCL = false
        var width: Int?
        var height: Int?
        var profile: Int?
        var level: Int?

        func flush() {
            guard currentHasVCL else {
                current.removeAll()
                return
            }
            // Same conversion as the production path (VT AVCC → AnnexB.accessUnit): strip
            // SEI/AUD/filler and in-band parameter sets, prefix SPS+PPS on IDRs.
            var avcc = Data()
            for n in current {
                var len = UInt32(n.count).bigEndian
                withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
                avcc.append(n)
            }
            let au = AnnexB.accessUnit(avccSlices: avcc, sps: sps, pps: pps)
            if !au.data.isEmpty { units.append(ClipAccessUnit(data: au.data, isKeyframe: au.isKeyframe)) }
            current.removeAll()
            currentHasVCL = false
        }

        for nal in nals {
            guard let type = AnnexB.nalType(nal) else { continue }
            let isVCL = type == H264NALType.nonIDRSlice.rawValue || type == H264NALType.idrSlice.rawValue
            if isVCL {
                // first_mb_in_slice == 0 (ue(v) "1" → top bit set) starts a new picture.
                let firstMbZero = nal.count > 1 && (nal[nal.startIndex + 1] & 0x80) != 0
                if currentHasVCL && firstMbZero { flush() }
                current.append(nal)
                currentHasVCL = true
                continue
            }
            // Non-VCL NAL after a picture starts the next access unit (SPS/PPS/SEI/AUD).
            if currentHasVCL, [6, 7, 8, 9].contains(type) { flush() }
            switch type {
            case H264NALType.sps.rawValue:
                sps = [nal]
                if let info = H264SPSInfo.parse(nal) {
                    width = info.width
                    height = info.height
                    profile = info.profileIdc
                    level = info.levelIdc
                }
            case H264NALType.pps.rawValue:
                pps = [nal]
            default:
                break // SEI/AUD/filler/end-of-seq: dropped like the production converter
            }
        }
        flush()
        guard !units.isEmpty else { throw ClipError.noAccessUnits(url.path) }
        guard units.contains(where: \.isKeyframe) else { throw ClipError.noKeyframe(url.path) }
        return LoadedClip(url: url, units: units, width: width, height: height, profileIdc: profile, levelIdc: level)
    }

    /// The ffmpeg command used by tools/fakedash for its clips.
    static func ffmpegArguments(width: Int, height: Int, output: URL) -> [String] {
        ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=\(width)x\(height):rate=20",
         "-t", "3", "-c:v", "libx264", "-profile:v", "baseline", "-level", "3.1", "-bf", "0", "-g", "20",
         "-pix_fmt", "yuv420p", "-f", "h264", output.path]
    }

    /// Generates `clip_<w>x<h>.h264` with ffmpeg (blocking; call off the media path).
    static func generate(width: Int, height: Int, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let out = directory.appendingPathComponent("clip_\(width)x\(height).h264")
        let tmp = directory.appendingPathComponent(".clip_\(width)x\(height).\(ProcessInfo.processInfo.processIdentifier).h264")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["ffmpeg"] + ffmpegArguments(width: width, height: height, output: tmp)
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            throw ClipError.generationFailed("cannot run ffmpeg: \(error)")
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw ClipError.generationFailed("exit \(p.terminationStatus): \(String(decoding: errData, as: UTF8.self).prefix(300))")
        }
        _ = try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }
}

/// Minimal SPS parser (width/height/profile/level) for clip sanity checks.
struct H264SPSInfo {
    let profileIdc: Int
    let levelIdc: Int
    let width: Int
    let height: Int

    static func parse(_ nal: Data) -> H264SPSInfo? {
        let bytes = [UInt8](nal)
        guard bytes.count > 4, bytes[0] & 0x1F == 7 else { return nil }
        // RBSP: drop emulation-prevention bytes (00 00 03 → 00 00).
        var rbsp: [UInt8] = []
        rbsp.reserveCapacity(bytes.count)
        var zeros = 0
        for b in bytes.dropFirst() {
            if zeros >= 2 && b == 3 {
                zeros = 0
                continue
            }
            rbsp.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        var r = BitReader(rbsp)
        guard let profile = r.u(8), r.u(8) != nil, let level = r.u(8), r.ue() != nil else { return nil }
        var chromaFormat = 1
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            guard let cf = r.ue() else { return nil }
            chromaFormat = cf
            if cf == 3 { _ = r.u(1) }
            guard r.ue() != nil, r.ue() != nil, r.u(1) != nil, let scaling = r.u(1) else { return nil }
            if scaling == 1 { return nil } // scaling lists: not needed for our clips
        }
        guard r.ue() != nil, let pocType = r.ue() else { return nil } // log2_max_frame_num, poc type
        if pocType == 0 {
            guard r.ue() != nil else { return nil }
        } else if pocType == 1 {
            guard r.u(1) != nil, r.se() != nil, r.se() != nil, let n = r.ue() else { return nil }
            for _ in 0 ..< n { guard r.se() != nil else { return nil } }
        }
        guard r.ue() != nil, r.u(1) != nil, let wMbs = r.ue(), let hMaps = r.ue(), let frameMbsOnly = r.u(1) else { return nil }
        if frameMbsOnly == 0 { _ = r.u(1) }
        guard r.u(1) != nil, let cropping = r.u(1) else { return nil }
        var cl = 0, cr = 0, ct = 0, cb = 0
        if cropping == 1 {
            guard let a = r.ue(), let b = r.ue(), let c = r.ue(), let d = r.ue() else { return nil }
            (cl, cr, ct, cb) = (a, b, c, d)
        }
        let cropUnitX = chromaFormat == 0 ? 1 : (chromaFormat == 3 ? 1 : 2)
        let subHeight = chromaFormat == 1 ? 2 : 1
        let cropUnitY = (chromaFormat == 0 ? 1 : subHeight) * (2 - frameMbsOnly)
        let width = (wMbs + 1) * 16 - (cl + cr) * cropUnitX
        let height = (hMaps + 1) * 16 * (2 - frameMbsOnly) - (ct + cb) * cropUnitY
        return H264SPSInfo(profileIdc: profile, levelIdc: level, width: width, height: height)
    }

    private struct BitReader {
        let data: [UInt8]
        var pos = 0
        init(_ d: [UInt8]) { data = d }
        mutating func u(_ n: Int) -> Int? {
            var v = 0
            for _ in 0 ..< n {
                guard pos < data.count * 8 else { return nil }
                let bit = (data[pos / 8] >> (7 - UInt8(pos % 8))) & 1
                v = (v << 1) | Int(bit)
                pos += 1
            }
            return v
        }
        mutating func ue() -> Int? {
            var zeros = 0
            while true {
                guard let b = u(1) else { return nil }
                if b == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            guard let rest = u(zeros) else { return nil }
            return (1 << zeros) - 1 + rest
        }
        mutating func se() -> Int? {
            guard let k = ue() else { return nil }
            return k % 2 == 1 ? (k + 1) / 2 : -(k / 2)
        }
    }
}

/// Counters exposed in the run summary.
struct FrameSourceStats: Sendable {
    var prepares = 0
    var resyncs = 0
    var mediaStops = 0
    var framesServed = 0
    var keyframesServed = 0
    var bytesServed = 0
    var nilReturns = 0
    var gateSeeks = 0
    var loops = 0
    var clip: String?
    var clipWidth: Int?
    var clipHeight: Int?
    var canvas: VideoCanvas?
    var parameters: EncoderParameters?
    var clipMismatch: String?
    var contractViolations: [String] = []
}

final class SyntheticFrameSource: VideoFrameSource, @unchecked Sendable {
    typealias Logger = @Sendable (String) -> Void

    private let explicitClip: URL?
    private let clipDirectory: URL?
    private let cacheDirectory: URL
    /// Encoder emulation: at most this many frames per second (0 = serve every pull immediately).
    private let sourceFPS: Double
    private let log: Logger

    private let lock = NSLock()
    private var clips: [String: LoadedClip] = [:] // by path
    private var clip: LoadedClip?
    private var canvas: VideoCanvas?
    private var cursor = 0
    private var gateClosed = true
    private var sequence: UInt64 = 0
    private var lastServed: (index: Int, key: Bool)?
    private var nextDue: UInt64 = 0
    private var loadToken = 0
    private var _stats = FrameSourceStats()

    init(explicitClip: URL?, clipDirectory: URL?, cacheDirectory: URL, sourceFPS: Double, log: @escaping Logger) {
        self.explicitClip = explicitClip
        self.clipDirectory = clipDirectory
        self.cacheDirectory = cacheDirectory
        self.sourceFPS = max(0, sourceFPS)
        self.log = log
    }

    var stats: FrameSourceStats {
        lock.lock()
        defer { lock.unlock() }
        return _stats
    }

    // MARK: VideoFrameSource

    func prepare(canvas: VideoCanvas, parameters: EncoderParameters) {
        lock.lock()
        _stats.prepares += 1
        _stats.canvas = canvas
        _stats.parameters = parameters
        self.canvas = canvas
        gateClosed = true
        lastServed = nil
        nextDue = 0
        loadToken += 1
        let token = loadToken
        lock.unlock()
        log("[source] prepare canvas=\(canvas) bitrate=\(parameters.bitrate) fps=\(parameters.frameRate) idr=\(parameters.keyframeIntervalSeconds)s baseline=\(parameters.forceBaseline)")

        let candidates = candidateURLs(for: canvas)
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            install(url: url, canvas: canvas, token: token)
            return
        }
        // Missing clip: generate it in the background (nextFrame waits for it up to its timeout).
        log("[source] no clip for \(canvas.width)x\(canvas.height) in \(candidates.map(\.path)) — generating with ffmpeg")
        lock.lock()
        clip = nil
        lock.unlock()
        let dir = cacheDirectory
        Thread.detachNewThread { [weak self] in
            do {
                let url = try ClipLoader.generate(width: canvas.width, height: canvas.height, into: dir)
                self?.install(url: url, canvas: canvas, token: token)
            } catch {
                self?.log("[source] !! \(error)")
            }
        }
    }

    func resynchronize() {
        lock.lock()
        _stats.resyncs += 1
        gateClosed = true
        nextDue = 0 // a forced IDR is encoded immediately
        lock.unlock()
        log("[source] resynchronize → next frame is an IDR")
    }

    func nextFrame(timeout: TimeInterval) async -> EncodedFrame? {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        // 1. Wait for a clip (only while ffmpeg generates a missing one).
        while currentClip() == nil {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nilFrame("no clip loaded within \(timeout)s") }
            await waitForLoad(maxNanos: deadline - now)
        }
        // 2. Encoder pacing (optional): not before the next frame is "encoded".
        if sourceFPS > 0 {
            let due = currentDue()
            let now = DispatchTime.now().uptimeNanoseconds
            if due > now {
                let wait = min(due, deadline) - now
                try? await Task.sleep(nanoseconds: wait)
                if due > deadline { return nilFrame("encoder pacing exceeded the pull timeout") }
            }
        }
        // 3. Serve the next access unit.
        guard let frame = serveNext() else { return nilFrame("no clip") }
        return frame
    }

    /// Synchronous critical section of `nextFrame` (never spans an await).
    private func serveNext() -> EncodedFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let clip, !clip.units.isEmpty else { return nil }
        let count = clip.units.count
        if gateClosed {
            // Keyframe gate: jump to the next IDR at or after the cursor (wrapping).
            var i = cursor % count
            var steps = 0
            while !clip.units[i].isKeyframe && steps < count {
                i = (i + 1) % count
                steps += 1
            }
            if i != cursor % count { _stats.gateSeeks += 1 }
            cursor = i
            gateClosed = false
        }
        let index = cursor % count
        let unit = clip.units[index]
        cursor = (index + 1) % count
        if cursor == 0 { _stats.loops += 1 }
        // Self-check of the contract (should never trigger).
        if let last = lastServed, last.index == index, !unit.isKeyframe, count > 1 {
            _stats.contractViolations.append("repeated P-frame index \(index)")
        }
        lastServed = (index, unit.isKeyframe)
        sequence += 1
        _stats.framesServed += 1
        _stats.bytesServed += unit.data.count
        if unit.isKeyframe { _stats.keyframesServed += 1 }
        if sourceFPS > 0 {
            let now = DispatchTime.now().uptimeNanoseconds
            nextDue = max(nextDue, now) + UInt64(1_000_000_000 / sourceFPS)
        }
        return EncodedFrame(accessUnit: unit.data, isKeyframe: unit.isKeyframe,
                            presentationTime: ProcessInfo.processInfo.systemUptime, sequence: sequence)
    }

    private func currentDue() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return nextDue
    }

    func mediaStopped() {
        lock.lock()
        _stats.mediaStops += 1
        gateClosed = true
        lastServed = nil
        nextDue = 0
        lock.unlock()
        log("[source] media stopped")
    }

    // MARK: Internals

    private func candidateURLs(for canvas: VideoCanvas) -> [URL] {
        if let explicitClip { return [explicitClip] }
        let name = "clip_\(canvas.width)x\(canvas.height).h264"
        var out: [URL] = []
        if let clipDirectory { out.append(clipDirectory.appendingPathComponent(name)) }
        out.append(cacheDirectory.appendingPathComponent(name))
        return out
    }

    private func install(url: URL, canvas: VideoCanvas, token: Int) {
        let loaded: LoadedClip
        lock.lock()
        let cached = clips[url.path]
        lock.unlock()
        if let cached {
            loaded = cached
        } else {
            do {
                loaded = try ClipLoader.load(url)
            } catch {
                log("[source] !! \(error)")
                return
            }
        }
        var mismatch: String?
        if let w = loaded.width, let h = loaded.height, w != canvas.width || h != canvas.height {
            mismatch = "clip \(url.lastPathComponent) is \(w)x\(h) but the canvas is \(canvas.width)x\(canvas.height)"
        }
        lock.lock()
        clips[url.path] = loaded
        if token == loadToken {
            clip = loaded
            cursor = 0
            gateClosed = true
            _stats.clip = url.path
            _stats.clipWidth = loaded.width
            _stats.clipHeight = loaded.height
            _stats.clipMismatch = mismatch
        }
        lock.unlock()
        let keys = loaded.keyframeIndices
        log("[source] clip \(url.path): \(loaded.units.count) AUs, \(keys.count) IDRs at \(keys.prefix(6).map(String.init).joined(separator: ","))\(keys.count > 6 ? ",…" : ""), SPS \(loaded.width.map(String.init) ?? "?")x\(loaded.height.map(String.init) ?? "?") profile_idc=\(loaded.profileIdc.map(String.init) ?? "?") level_idc=\(loaded.levelIdc.map(String.init) ?? "?")")
        if let mismatch { log("[source] !! \(mismatch) — the dash will flag FRAME_SIZE_MISMATCH") }
    }

    private func currentClip() -> LoadedClip? {
        lock.lock()
        defer { lock.unlock() }
        return clip
    }

    /// Only while ffmpeg generates a missing clip (rare): re-check every 50 ms.
    private func waitForLoad(maxNanos: UInt64) async {
        try? await Task.sleep(nanoseconds: min(maxNanos, 50_000_000))
    }

    private func nilFrame(_ why: String) -> EncodedFrame? {
        lock.lock()
        _stats.nilReturns += 1
        let n = _stats.nilReturns
        lock.unlock()
        if n <= 5 || n % 50 == 0 { log("[source] nextFrame → nil (\(why)) #\(n)") }
        return nil
    }
}
