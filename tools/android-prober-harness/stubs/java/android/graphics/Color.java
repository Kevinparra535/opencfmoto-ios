// HARNESS STUB (not Android code).
package android.graphics;

public final class Color {
    private Color() {}
    public static final int BLACK = 0xFF000000;
    public static final int WHITE = 0xFFFFFFFF;
    public static final int TRANSPARENT = 0;
    public static int parseColor(String s) {
        String h = s.startsWith("#") ? s.substring(1) : s;
        long v = Long.parseLong(h, 16);
        if (h.length() == 6) v |= 0xFF000000L;
        return (int) v;
    }
}
