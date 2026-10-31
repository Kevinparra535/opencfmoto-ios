// HARNESS STUB (not Android code).
package android.os;

import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Set;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

public class Handler {
    private final Looper looper;
    private final Set<ScheduledFuture<?>> pending = Collections.newSetFromMap(new IdentityHashMap<>());

    public Handler() { this(Looper.getMainLooper()); }
    public Handler(Looper looper) { this.looper = looper; }

    private Runnable guard(Runnable r) {
        return () -> {
            try { r.run(); } catch (Throwable t) { System.out.println("[harness] main-looper task threw: " + t); }
        };
    }

    public final boolean post(Runnable r) { return postDelayed(r, 0); }

    public final boolean postDelayed(Runnable r, long delayMillis) {
        try {
            ScheduledFuture<?> f = looper.exec.schedule(guard(r), Math.max(0, delayMillis), TimeUnit.MILLISECONDS);
            synchronized (pending) { pending.removeIf(java.util.concurrent.Future::isDone); pending.add(f); }
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    public final void removeCallbacksAndMessages(Object token) {
        synchronized (pending) { for (ScheduledFuture<?> f : pending) f.cancel(false); pending.clear(); }
    }

    public final Looper getLooper() { return looper; }
}
