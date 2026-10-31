// HARNESS STUB (not Android code).
package android.widget;

import android.content.Context;
import android.view.ViewGroup;

public class LinearLayout extends ViewGroup {
    public static final int HORIZONTAL = 0;
    public static final int VERTICAL = 1;
    private int orientation; private int gravity;
    public LinearLayout(Context context) { super(context); }
    public int getOrientation() { return orientation; }
    public void setOrientation(int o) { orientation = o; }
    public int getGravity() { return gravity; }
    public void setGravity(int g) { gravity = g; }
}
