// HARNESS STUB (not Android code). Monotonic clocks.
package android.os;

public final class SystemClock {
    private SystemClock() {}
    private static final long BASE = System.nanoTime();
    public static long elapsedRealtime() { return (System.nanoTime() - BASE) / 1_000_000L + 60_000L; }
    public static long uptimeMillis() { return elapsedRealtime(); }
    public static void sleep(long ms) { try { Thread.sleep(ms); } catch (InterruptedException ignored) { } }
}
