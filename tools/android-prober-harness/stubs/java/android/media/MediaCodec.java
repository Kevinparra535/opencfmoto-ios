// HARNESS STUB (not Android code). A fake surface-input AVC *encoder* for VideoPipeline.kt:
//  - start(): emits INFO_OUTPUT_FORMAT_CHANGED, then one BUFFER_FLAG_CODEC_CONFIG buffer
//    (00000001 SPS 00000001 PPS of the clip), then the clip's access units (VCL NALs only, IDR
//    flagged BUFFER_FLAG_KEY_FRAME) at -Dharness.content.fps (default 20, the clip's rate),
//    looping the clip. This stands in for "the Presentation/VirtualDisplay keeps drawing".
//  - setParameters(PARAMETER_KEY_REQUEST_SYNC_FRAME): the next output is an IDR (the replay jumps
//    to the next GOP start of the clip), like a hardware encoder honouring request-sync.
//  - KEY_REPEAT_PREVIOUS_FRAME_AFTER is accepted but never needed: the source never goes static.
// Everything downstream (codec-config prepend, awaitKeyframe drop, 8-deep drop-oldest queue,
// pollFrame(1500)) is the untouched upstream VideoPipeline.kt.
package android.media;

import android.os.Bundle;
import android.view.Surface;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.locks.LockSupport;

public final class MediaCodec {
    public static final int BUFFER_FLAG_SYNC_FRAME = 1;
    public static final int BUFFER_FLAG_KEY_FRAME = 1;
    public static final int BUFFER_FLAG_CODEC_CONFIG = 2;
    public static final int BUFFER_FLAG_END_OF_STREAM = 4;
    public static final int CONFIGURE_FLAG_ENCODE = 1;
    public static final int INFO_TRY_AGAIN_LATER = -1;
    public static final int INFO_OUTPUT_FORMAT_CHANGED = -2;
    public static final String PARAMETER_KEY_REQUEST_SYNC_FRAME = "request-sync";
    public static final String PARAMETER_KEY_VIDEO_BITRATE = "video-bitrate";

    public static final class BufferInfo {
        public int offset;
        public int size;
        public long presentationTimeUs;
        public int flags;
        public void set(int newOffset, int newSize, long newTimeUs, int newFlags) {
            offset = newOffset; size = newSize; presentationTimeUs = newTimeUs; flags = newFlags;
        }
    }

    private static final int KIND_FORMAT = 0, KIND_BUFFER = 1;
    private static final class Out {
        final int kind; final byte[] data; final int flags; final long ptsUs;
        Out(int kind, byte[] data, int flags, long ptsUs) { this.kind = kind; this.data = data; this.flags = flags; this.ptsUs = ptsUs; }
    }
    private static final AtomicInteger INSTANCES = new AtomicInteger();

    private final int id = INSTANCES.incrementAndGet();
    private MediaFormat format;
    private MediaFormat outFormat;
    private HarnessClipSource clip;
    private volatile boolean running;
    private volatile boolean syncRequested;
    private Thread producer;
    private final LinkedBlockingQueue<Out> outQ = new LinkedBlockingQueue<>();
    private final ConcurrentHashMap<Integer, ByteBuffer> outBufs = new ConcurrentHashMap<>();
    private final AtomicInteger nextIdx = new AtomicInteger();

    private MediaCodec() { }

    private void log(String msg) { android.util.Log.i("harness", "[fake-encoder#" + id + "] " + msg); }

    public static MediaCodec createEncoderByType(String type) throws IOException {
        if (!MediaFormat.MIMETYPE_VIDEO_AVC.equals(type)) throw new IOException("harness: no encoder for " + type);
        return new MediaCodec();
    }

    public void configure(MediaFormat format, Surface surface, MediaCrypto crypto, int flags) {
        if ((flags & CONFIGURE_FLAG_ENCODE) == 0) throw new IllegalArgumentException("harness: encoder only");
        this.format = format.copy();
        log("configure " + format);
    }

    public Surface createInputSurface() { return new Surface(); }

    public void start() {
        int w = format.getInteger(MediaFormat.KEY_WIDTH), h = format.getInteger(MediaFormat.KEY_HEIGHT);
        try {
            clip = HarnessClipSource.forSize(w, h);
        } catch (IOException e) {
            throw new IllegalStateException("harness: no clip for " + w + "x" + h + ": " + e.getMessage(), e);
        }
        outFormat = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h);
        running = true;
        outQ.add(new Out(KIND_FORMAT, null, 0, 0));
        outQ.add(new Out(KIND_BUFFER, clip.codecConfig, BUFFER_FLAG_CODEC_CONFIG, 0));
        log("start " + w + "x" + h + " clip=" + clip.path + " aus=" + clip.aus.length + " gop=" + clip.gop
                + " contentFps=" + contentFps() + " codecConfig=" + clip.codecConfig.length + "b");
        producer = new Thread(this::produce, "harness-fake-encoder-" + id);
        producer.setDaemon(true);
        producer.start();
    }

    private static double contentFps() {
        try { return Math.max(0.5, Double.parseDouble(System.getProperty("harness.content.fps", "20"))); }
        catch (NumberFormatException e) { return 20.0; }
    }

    private void produce() {
        double fps = contentFps();
        long period = (long) (1e9 / fps);
        long next = System.nanoTime();
        int pos = 0;
        long frames = 0;
        int n = clip.aus.length;
        while (running) {
            if (syncRequested) {
                syncRequested = false;
                int k = clip.nextKeyAtOrAfter(pos);
                log("request-sync → next output is IDR (clip AU #" + k + ", skipped " + ((k - pos + n) % n) + " AUs)");
                pos = k;
            }
            HarnessClipSource.Au au = clip.aus[pos];
            outQ.add(new Out(KIND_BUFFER, au.vcl, au.key ? BUFFER_FLAG_KEY_FRAME : 0, (long) (frames * 1e6 / fps)));
            frames++;
            pos = (pos + 1) % n;
            next += period;
            long sleep = next - System.nanoTime();
            if (sleep > 0) LockSupport.parkNanos(sleep);
            else if (sleep < -5 * period) next = System.nanoTime();
            if (Thread.interrupted()) break;
        }
    }

    public int dequeueOutputBuffer(BufferInfo info, long timeoutUs) {
        if (!running) throw new IllegalStateException("harness: codec is not started");
        Out o;
        try {
            o = timeoutUs < 0 ? outQ.take() : outQ.poll(timeoutUs, TimeUnit.MICROSECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return INFO_TRY_AGAIN_LATER;
        }
        if (o == null) return INFO_TRY_AGAIN_LATER;
        if (o.kind == KIND_FORMAT) return INFO_OUTPUT_FORMAT_CHANGED;
        int idx = nextIdx.getAndIncrement() & 0x3FFFFFFF;
        outBufs.put(idx, ByteBuffer.wrap(o.data).asReadOnlyBuffer());
        info.set(0, o.data.length, o.ptsUs, o.flags);
        return idx;
    }

    public ByteBuffer getOutputBuffer(int index) { return outBufs.get(index); }

    public void releaseOutputBuffer(int index, boolean render) { outBufs.remove(index); }

    public MediaFormat getOutputFormat() {
        if (outFormat == null) throw new IllegalStateException("harness: not started");
        return outFormat;
    }

    public void setParameters(Bundle params) {
        if (params.containsKey(PARAMETER_KEY_REQUEST_SYNC_FRAME)) syncRequested = true;
        if (params.containsKey(PARAMETER_KEY_VIDEO_BITRATE)) log("bitrate → " + params.getInt(PARAMETER_KEY_VIDEO_BITRATE) + " (ignored by replay)");
    }

    public void stop() {
        if (running) log("stop");
        running = false;
        Thread p = producer;
        if (p != null) p.interrupt();
        outQ.clear();
        outBufs.clear();
    }

    public void release() { stop(); }

    public void reset() { stop(); format = null; }
}
