// HARNESS STUB (not Android code). ProjectionHolder.projection stays null (own-content mode).
package android.media.projection;

import android.hardware.display.VirtualDisplay;
import android.os.Handler;
import android.view.Surface;

public class MediaProjection {
    public static abstract class Callback {
        public void onStop() { }
        public void onCapturedContentResize(int width, int height) { }
        public void onCapturedContentVisibilityChanged(boolean isVisible) { }
    }
    public void registerCallback(Callback callback, Handler handler) { }
    public void unregisterCallback(Callback callback) { }
    public VirtualDisplay createVirtualDisplay(String name, int width, int height, int dpi, int flags,
                                               Surface surface, VirtualDisplay.Callback callback, Handler handler) {
        return new VirtualDisplay();
    }
    public void stop() { }
}
