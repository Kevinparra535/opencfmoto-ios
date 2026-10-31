// HARNESS STUB (not Android code).
package android.view;

public class Surface {
    private volatile boolean released;
    public void release() { released = true; }
    public boolean isValid() { return !released; }
}
