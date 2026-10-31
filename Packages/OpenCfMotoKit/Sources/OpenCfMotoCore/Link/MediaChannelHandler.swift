// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnProber.kt (mediaLoop / handleMediaReq / sendFrameRaw)
//
// One handler per media connection (:10921 or :10920 — port-agnostic: every command is handled on
// whichever socket it arrives and answered on that socket). See docs/spec/media-video.md §4.

import Foundation

/// What the engine must know about a handled media message.
public enum MediaChannelEvent: Sendable, Equatable {
    /// REQ 16 with a usable size: canvas negotiated (and `prepare` called).
    case canvasNegotiated(VideoCanvas)
    /// REQ 16 whose width or height rounds to 0: the previous canvas was replied instead.
    case canvasRejected(requestedWidth: Int, requestedHeight: Int, kept: VideoCanvas)
    /// REQ 112 (or 128): the source was resynchronized before the reply.
    case mediaStarted
    /// A frame was written for a 114. `number` restarts at 1 after every reconnect.
    case frameSent(number: Int, bytes: Int, keyframe: Bool)
    /// A 114 got no frame within the pull timeout (nothing sent).
    case pullMissed
    /// A touch frame (cmd 32) was decoded and handed to the touch sink (never answered).
    case touch(PxcTouchFrame)
    /// A cmd 32 body shorter than 8 bytes (dropped).
    case touchTooShort(Int)
    /// Unknown cmdType: logged, not answered.
    case unknown(Int16)
}

public final class MediaChannelHandler: @unchecked Sendable {
    public let context: LinkSessionContext
    public let tag: String
    private let frameSource: VideoFrameSource
    private let stats: LinkStatsTracker
    private let framePullTimeout: TimeInterval
    private let resynchronizeOnStartH264: Bool
    private let encoderParameters: @Sendable (BikeProfile, VideoCanvas) -> EncoderParameters
    private let touchSink: @Sendable (PxcTouchFrame) -> Void

    /// - Parameters:
    ///   - framePullTimeout: how long a 114 may wait in `VideoFrameSource.nextFrame`.
    ///   - encoderParameters: parameters for `prepare` (default: the profile's encoder defaults).
    ///   - touchSink: receives decoded touch frames (the ghost filter).
    public init(context: LinkSessionContext, frameSource: VideoFrameSource, stats: LinkStatsTracker,
                framePullTimeout: TimeInterval, tag: String, resynchronizeOnStartH264: Bool = true,
                encoderParameters: (@Sendable (BikeProfile, VideoCanvas) -> EncoderParameters)? = nil,
                touchSink: @escaping @Sendable (PxcTouchFrame) -> Void) {
        self.context = context
        self.frameSource = frameSource
        self.stats = stats
        self.framePullTimeout = framePullTimeout
        self.tag = tag
        self.resynchronizeOnStartH264 = resynchronizeOnStartH264
        self.encoderParameters = encoderParameters ?? { profile, _ in profile.encoderDefaults }
        self.touchSink = touchSink
    }

    /// Handles one message. Replies go through `write` (ONE call per reply / frame, on this
    /// connection). A thrown write error ends the connection (Android closes the socket).
    public func handle(_ message: MediaMessage, write: @Sendable (Data) async throws -> Void) async throws -> [MediaChannelEvent] {
        switch message.cmdType {
        case MediaCmd.reqConfigCapture:
            return try await onConfigCapture(message, write: write)
        case MediaCmd.reqGetVersion:
            Log.i("LINK", "[\(tag)] REQ_GET_VERSION → RLY 49")
            try await write(MediaReplies.getVersion.encoded())
            return []
        case MediaCmd.reqHeartbeat:
            try await write(MediaReplies.heartbeat.encoded())
            return []
        case MediaCmd.reqConfigCaptureExtend:
            let text = String(String(decoding: message.body, as: UTF8.self).prefix(120))
            Log.i("LINK", "[\(tag)] REQ_CONFIGCAPTUREREXTEND len=\(message.body.count) \(text) → RLY 97")
            try await write(MediaReplies.configCaptureExtend.encoded())
            return []
        case MediaCmd.reqDataStart:
            startMedia(reason: "REQ_RV_DATA_START(112)")
            Log.i("LINK", "[\(tag)] → RLY 113")
            try await write(MediaReplies.dataStart.encoded())
            return [.mediaStarted]
        case MediaCmd.reqStartH264:
            Log.i("LINK", "[\(tag)] *** REQ_START_H264 *** len=\(message.body.count) → RLY 129")
            if resynchronizeOnStartH264 { startMedia(reason: "REQ_START_H264(128)") }
            try await write(MediaReplies.startH264.encoded())
            return resynchronizeOnStartH264 ? [.mediaStarted] : []
        case MediaCmd.reqDataNext:
            return try await onDataNext(write: write)
        case MediaCmd.touch:
            guard let touch = PxcTouchFrame.decode(message.body) else {
                Log.w("LINK", "[\(tag)] touch frame too short (\(message.body.count)b)")
                return [.touchTooShort(message.body.count)]
            }
            touchSink(touch)
            return [.touch(touch)]
        default:
            Log.i("LINK", "[\(tag)] media cmdType=\(message.cmdType) len=\(message.body.count) token=\(message.token) \(message.body.prefix(32).hexDump(limit: 32))")
            return [.unknown(message.cmdType)]
        }
    }

    // MARK: - Commands

    private func onConfigCapture(_ message: MediaMessage, write: @Sendable (Data) async throws -> Void) async throws -> [MediaChannelEvent] {
        let req = ConfigCaptureRequest(body: message.body)
        Log.i("LINK", "[\(tag)] \(req.description) token=\(message.token)")
        Log.i("LINK", "[\(tag)] REQ_CONFIG_CAPTURE extra: \(req.extraFieldsDescription) body=\(message.body.hexDump(limit: 40))")
        let profile = context.activeProfile
        if req.hasUsableSize {
            let canvas = req.canvas
            context.setCanvas(canvas)
            prepare(canvas, profile: profile)
            Log.i("LINK", "[\(tag)] → RLY_CONFIG_CAPTURE(17) encoder=\(req.replyEncoder) w=\(canvas.width) h=\(canvas.height)")
            try await write(req.reply().encoded())
            return [.canvasNegotiated(canvas)]
        }
        // Guard (not in Android): never reply a 0 dimension — keep the previous canvas.
        let kept = context.canvas
        Log.e("LINK", "[\(tag)] !! REQ_CONFIG_CAPTURE without a usable size (\(req.deviceWidth)x\(req.deviceHeight)) — keeping \(kept.width)x\(kept.height)")
        let reply = ConfigCaptureReply(encoder: req.replyEncoder, width: kept.width, height: kept.height,
                                       supportExtendProtocol: req.supportExtendProtocol)
        prepare(kept, profile: profile)
        try await write(reply.message.encoded())
        return [.canvasRejected(requestedWidth: req.deviceWidth, requestedHeight: req.deviceHeight, kept: kept)]
    }

    private func prepare(_ canvas: VideoCanvas, profile: BikeProfile) {
        let params = encoderParameters(profile, canvas)
        frameSource.prepare(canvas: canvas, parameters: params)
        context.markMediaPrepared(true)
    }

    /// The 112 sequence: make sure the source is prepared (Android creates the encoder at 112 when
    /// no REQ 16 configured it), then resynchronize (gate, flush, forced IDR) — BEFORE the reply.
    private func startMedia(reason: String) {
        let canvas = context.canvas
        if !context.mediaPrepared {
            Log.i("LINK", "[\(tag)] \(reason): starting video \(canvas.width)x\(canvas.height)")
            prepare(canvas, profile: context.activeProfile)
        } else {
            Log.i("LINK", "[\(tag)] \(reason): video \(canvas.width)x\(canvas.height)")
        }
        frameSource.resynchronize()
        Log.i("LINK", "[VIDEO] bike attached → flushed queue + requested IDR (first frame will be a keyframe)")
    }

    private func onDataNext(write: @Sendable (Data) async throws -> Void) async throws -> [MediaChannelEvent] {
        stats.recordPull()
        guard let frame = await frameSource.nextFrame(timeout: framePullTimeout) else {
            stats.recordMissedPull()
            Log.shared.throttled("no-frame-\(tag)", interval: 1, .warn, "LINK", "[\(tag)] REQ_RV_DATA_NEXT(114): no frame ready")
            return [.pullMissed]
        }
        guard !frame.accessUnit.isEmpty else {
            // Never send a zero-size frame (media-video.md §15.2).
            stats.recordMissedPull()
            Log.w("LINK", "[\(tag)] REQ_RV_DATA_NEXT(114): source returned an empty access unit — not sent")
            return [.pullMissed]
        }
        let bytes = frame.wireBytes
        try await write(bytes) // ONE write: [size i32 LE][Annex-B AU]
        let n = stats.recordFrameSent(wireBytes: bytes.count, keyframe: frame.isKeyframe)
        if n <= 5 || n % 60 == 0 {
            Log.i("LINK", "[\(tag)] sent frame #\(n) (\(frame.accessUnit.count)b\(frame.isKeyframe ? ", key" : ""))")
        }
        return [.frameSent(number: n, bytes: bytes.count, keyframe: frame.isKeyframe)]
    }
}
