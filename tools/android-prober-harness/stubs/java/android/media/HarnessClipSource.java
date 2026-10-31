// HARNESS STUB (not Android code). Loads an H.264 Annex-B clip (tools/fakedash/clips/clip_WxH.h264,
// generated with ffmpeg if missing) and splits it into access units the way a MediaCodec AVC
// encoder hands them out: one CODEC_CONFIG buffer (00000001 SPS 00000001 PPS) and then per frame
// only the VCL NAL units (IDR frames flagged KEY_FRAME). SPS/PPS/SEI/AUD repeated inside the clip
// are dropped because Android's VideoPipeline.drainLoop prepends the codec config to keyframes itself.
package android.media;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

final class HarnessClipSource {
    static final class Au {
        final int index; final boolean key; final byte[] vcl;
        Au(int index, boolean key, byte[] vcl) { this.index = index; this.key = key; this.vcl = vcl; }
    }

    final String path;
    final byte[] codecConfig;
    final Au[] aus;
    final int gop;

    private static final Map<String, HarnessClipSource> CACHE = new HashMap<>();
    private static final byte[] SC = {0, 0, 0, 1};

    static synchronized HarnessClipSource forSize(int w, int h) throws IOException {
        String key = w + "x" + h;
        HarnessClipSource c = CACHE.get(key);
        if (c == null) {
            File f = locate(w, h);
            c = new HarnessClipSource(f.getAbsolutePath(), Files.readAllBytes(f.toPath()));
            CACHE.put(key, c);
        }
        return c;
    }

    private static File locate(int w, int h) throws IOException {
        String name = "clip_" + w + "x" + h + ".h264";
        File dir = new File(System.getProperty("harness.clips.dir", "../fakedash/clips"));
        File f = new File(dir, name);
        if (f.isFile()) return f;
        File cacheDir = new File(System.getProperty("harness.clips.cache", System.getProperty("java.io.tmpdir")));
        cacheDir.mkdirs();
        File gen = new File(cacheDir, name);
        if (gen.isFile()) return gen;
        ProcessBuilder pb = new ProcessBuilder("ffmpeg", "-nostdin", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc=size=" + w + "x" + h + ":rate=20", "-t", "3",
                "-c:v", "libx264", "-profile:v", "baseline", "-level", "3.1", "-bf", "0", "-g", "20",
                "-pix_fmt", "yuv420p", "-f", "h264", gen.getAbsolutePath());
        pb.inheritIO();
        try {
            int rc = pb.start().waitFor();
            if (rc != 0 || !gen.isFile()) throw new IOException("ffmpeg failed (" + rc + ") for " + name);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IOException("interrupted generating " + name);
        }
        return gen;
    }

    private HarnessClipSource(String path, byte[] data) throws IOException {
        this.path = path;
        List<byte[]> nals = splitAnnexB(data);
        byte[] sps = null, pps = null;
        List<List<byte[]>> groups = new ArrayList<>();
        List<byte[]> cur = new ArrayList<>();
        boolean curHasVcl = false;
        for (byte[] nal : nals) {
            int type = nal[0] & 0x1F;
            boolean vcl = type == 1 || type == 5;
            boolean firstMb0 = vcl && nal.length > 1 && (nal[1] & 0x80) != 0; // ue(v) first_mb_in_slice == 0
            boolean startsAu = (vcl && firstMb0) || type == 6 || type == 7 || type == 8 || type == 9;
            if (startsAu && curHasVcl) { groups.add(cur); cur = new ArrayList<>(); curHasVcl = false; }
            if (type == 7 && sps == null) sps = nal;
            if (type == 8 && pps == null) pps = nal;
            cur.add(nal);
            if (vcl) curHasVcl = true;
        }
        if (curHasVcl) groups.add(cur);
        if (sps == null || pps == null) throw new IOException("clip has no SPS/PPS: " + path);
        ByteArrayOutputStream cfg = new ByteArrayOutputStream();
        cfg.write(SC); cfg.write(sps); cfg.write(SC); cfg.write(pps);
        codecConfig = cfg.toByteArray();
        List<Au> out = new ArrayList<>();
        int firstGop = -1;
        for (List<byte[]> g : groups) {
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            boolean key = false;
            for (byte[] nal : g) {
                int type = nal[0] & 0x1F;
                if (type == 1 || type == 5) { b.write(SC); b.write(nal); }
                if (type == 5) key = true;
            }
            if (key && out.size() > 0 && firstGop < 0) firstGop = out.size();
            out.add(new Au(out.size(), key, b.toByteArray()));
        }
        if (out.isEmpty() || !out.get(0).key) throw new IOException("clip must start with an IDR: " + path);
        aus = out.toArray(new Au[0]);
        gop = firstGop < 0 ? aus.length : firstGop;
    }

    /** Index of the first keyframe at or after {@code from} (wrapping). */
    int nextKeyAtOrAfter(int from) {
        for (int i = 0; i < aus.length; i++) {
            int j = (from + i) % aus.length;
            if (aus[j].key) return j;
        }
        return 0;
    }

    private static List<byte[]> splitAnnexB(byte[] d) {
        List<Integer> starts = new ArrayList<>(); // index of first NAL byte
        List<Integer> scStarts = new ArrayList<>(); // index of the start code's first byte
        int i = 0;
        while (i + 3 <= d.length) {
            if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
                int sc = (i > 0 && d[i - 1] == 0) ? i - 1 : i;
                scStarts.add(sc);
                starts.add(i + 3);
                i += 3;
            } else {
                i++;
            }
        }
        List<byte[]> nals = new ArrayList<>();
        for (int k = 0; k < starts.size(); k++) {
            int s = starts.get(k);
            int e = k + 1 < starts.size() ? scStarts.get(k + 1) : d.length;
            while (e > s && d[e - 1] == 0) e--; // trailing_zero_8bits
            if (e > s) {
                byte[] nal = new byte[e - s];
                System.arraycopy(d, s, nal, 0, e - s);
                nals.add(nal);
            }
        }
        return nals;
    }
}
