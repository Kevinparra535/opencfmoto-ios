// HARNESS STUB (not Android code).
package android.net.wifi;

public class WifiManager {
    public MulticastLock createMulticastLock(String tag) { return new MulticastLock(tag); }

    public static class MulticastLock {
        private final String tag;
        private boolean held;
        MulticastLock(String tag) { this.tag = tag; }
        public void setReferenceCounted(boolean refCounted) { }
        public void acquire() { held = true; }
        public void release() { held = false; }
        public boolean isHeld() { return held; }
    }
}
