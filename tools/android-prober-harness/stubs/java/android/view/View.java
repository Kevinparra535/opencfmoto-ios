// HARNESS STUB (not Android code).
package android.view;

import android.content.Context;

public class View {
    private final Context context;
    public View(Context context) { this.context = context; }
    public Context getContext() { return context; }
    public boolean post(Runnable action) { return new android.os.Handler().post(action); }
    public boolean dispatchTouchEvent(MotionEvent event) { return false; }
    public void setBackgroundColor(int color) { }
}
