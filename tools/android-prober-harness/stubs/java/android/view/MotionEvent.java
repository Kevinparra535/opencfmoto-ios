// HARNESS STUB (not Android code).
package android.view;

public final class MotionEvent {
    public static final int ACTION_DOWN = 0;
    public static final int ACTION_UP = 1;
    public static final int ACTION_MOVE = 2;
    private final int action; private final float x, y;
    private MotionEvent(int action, float x, float y) { this.action = action; this.x = x; this.y = y; }
    public static MotionEvent obtain(long downTime, long eventTime, int action, float x, float y, int metaState) {
        return new MotionEvent(action, x, y);
    }
    public int getAction() { return action; }
    public float getX() { return x; }
    public float getY() { return y; }
    public void recycle() { }
}
