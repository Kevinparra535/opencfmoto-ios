// HARNESS STUB (not Android code). logcat stand-in: one line per call on stdout, wall-clock stamped.
package android.util;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

public final class Log {
    private Log() {}
    private static final SimpleDateFormat TS = new SimpleDateFormat("HH:mm:ss.SSS", Locale.US);

    private static synchronized int print(char level, String tag, String msg) {
        System.out.println(TS.format(new Date()) + " " + level + "/" + tag + ": " + msg);
        System.out.flush();
        return 0;
    }
    public static int v(String tag, String msg) { return print('V', tag, msg); }
    public static int d(String tag, String msg) { return print('D', tag, msg); }
    public static int i(String tag, String msg) { return print('I', tag, msg); }
    public static int w(String tag, String msg) { return print('W', tag, msg); }
    public static int e(String tag, String msg) { return print('E', tag, msg); }
    public static int e(String tag, String msg, Throwable tr) { return print('E', tag, msg + " " + tr); }
}
