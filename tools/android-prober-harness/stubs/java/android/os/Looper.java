// HARNESS STUB (not Android code). A real single-threaded "main" looper so posted UI work runs.
package android.os;

import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;

public final class Looper {
    private static final Looper MAIN = new Looper("harness-main-looper");
    final ScheduledExecutorService exec;
    volatile Thread thread;

    private Looper(String name) {
        exec = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, name);
            t.setDaemon(true);
            thread = t;
            return t;
        });
    }

    public static Looper getMainLooper() { return MAIN; }
    public static Looper myLooper() { return Thread.currentThread() == MAIN.thread ? MAIN : null; }
}
