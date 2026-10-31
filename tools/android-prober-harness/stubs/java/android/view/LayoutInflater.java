// HARNESS STUB (not Android code). Only reachable from VideoPipeline.setupGpxPresentation (GPX mode, unused).
package android.view;

import android.content.Context;

public class LayoutInflater {
    private final Context context;
    private LayoutInflater(Context c) { context = c; }
    public static LayoutInflater from(Context context) { return new LayoutInflater(context); }
    public View inflate(int resource, ViewGroup root) { return new ViewGroup(context); }
}
