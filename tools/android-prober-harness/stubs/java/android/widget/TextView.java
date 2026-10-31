// HARNESS STUB (not Android code). Text changes are not rendered (the fake encoder replays a clip).
package android.widget;

import android.content.Context;
import android.view.View;

public class TextView extends View {
    private CharSequence text = "";
    private float textSize = 14f;
    private int gravity;
    public TextView(Context context) { super(context); }
    public CharSequence getText() { return text; }
    public void setText(CharSequence t) { text = t; }
    public float getTextSize() { return textSize; }
    public void setTextSize(float s) { textSize = s; }
    public int getGravity() { return gravity; }
    public void setGravity(int g) { gravity = g; }
    public void setTextColor(int color) { }
}
