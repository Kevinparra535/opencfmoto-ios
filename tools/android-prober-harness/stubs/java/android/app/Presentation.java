// HARNESS STUB (not Android code). No pixels are rendered: the fake MediaCodec replays a clip.
package android.app;

import android.content.Context;
import android.view.Display;
import android.view.View;
import android.view.Window;

public class Presentation {
    private final Context context;
    private final Window window = new Window();
    public Presentation(Context outerContext, Display display) { this.context = outerContext; }
    public Context getContext() { return context; }
    public Window getWindow() { return window; }
    public void setContentView(View view) { }
    public void show() { }
    public void dismiss() { }
}
