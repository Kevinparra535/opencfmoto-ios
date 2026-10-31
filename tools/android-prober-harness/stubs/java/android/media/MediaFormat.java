// HARNESS STUB (not Android code). Key strings as in android.jar.
package android.media;

import java.util.LinkedHashMap;
import java.util.Map;

public final class MediaFormat {
    public static final String MIMETYPE_VIDEO_AVC = "video/avc";
    public static final String KEY_MIME = "mime";
    public static final String KEY_WIDTH = "width";
    public static final String KEY_HEIGHT = "height";
    public static final String KEY_COLOR_FORMAT = "color-format";
    public static final String KEY_BIT_RATE = "bitrate";
    public static final String KEY_BITRATE_MODE = "bitrate-mode";
    public static final String KEY_FRAME_RATE = "frame-rate";
    public static final String KEY_I_FRAME_INTERVAL = "i-frame-interval";
    public static final String KEY_REPEAT_PREVIOUS_FRAME_AFTER = "repeat-previous-frame-after";
    public static final String KEY_LATENCY = "latency";
    public static final String KEY_PROFILE = "profile";
    public static final String KEY_LEVEL = "level";

    private final Map<String, Object> map = new LinkedHashMap<>();

    public static MediaFormat createVideoFormat(String mime, int width, int height) {
        MediaFormat f = new MediaFormat();
        f.map.put(KEY_MIME, mime);
        f.map.put(KEY_WIDTH, width);
        f.map.put(KEY_HEIGHT, height);
        return f;
    }
    public void setInteger(String name, int value) { map.put(name, value); }
    public void setLong(String name, long value) { map.put(name, value); }
    public void setString(String name, String value) { map.put(name, value); }
    public void setFloat(String name, float value) { map.put(name, value); }
    public int getInteger(String name) { return ((Number) map.get(name)).intValue(); }
    public int getInteger(String name, int def) { Object v = map.get(name); return v instanceof Number ? ((Number) v).intValue() : def; }
    public long getLong(String name) { return ((Number) map.get(name)).longValue(); }
    public long getLong(String name, long def) { Object v = map.get(name); return v instanceof Number ? ((Number) v).longValue() : def; }
    public String getString(String name) { Object v = map.get(name); return v == null ? null : v.toString(); }
    public boolean containsKey(String name) { return map.containsKey(name); }
    MediaFormat copy() { MediaFormat f = new MediaFormat(); f.map.putAll(map); return f; }
    @Override public String toString() { return "{" + map.toString().replaceAll("^\\{|\\}$", "") + "}"; }
}
