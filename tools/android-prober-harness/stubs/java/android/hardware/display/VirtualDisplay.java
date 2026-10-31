// HARNESS STUB (not Android code).
package android.hardware.display;

import android.view.Display;

public class VirtualDisplay {
    private final Display display = new Display();
    public Display getDisplay() { return display; }
    public void resize(int width, int height, int densityDpi) { }
    public void release() { }
    public static abstract class Callback {
        public void onPaused() { }
        public void onResumed() { }
        public void onStopped() { }
    }
}
