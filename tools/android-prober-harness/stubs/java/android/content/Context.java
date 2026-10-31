// HARNESS STUB (not Android code). Minimal stand-in for android.content.Context so the original
// OpenCfMoto sources compile and run on a desktop JVM. Only what the copied files touch.
package android.content;

import android.content.res.Resources;
import java.io.File;
import java.util.HashMap;
import java.util.Map;

public class Context {
    public static final String CONNECTIVITY_SERVICE = "connectivity";
    public static final String WIFI_SERVICE = "wifi";
    public static final String NSD_SERVICE = "servicediscovery";
    public static final String DISPLAY_SERVICE = "display";
    public static final int MODE_PRIVATE = 0;

    private final Map<String, Object> services = new HashMap<>();
    private final Map<String, SharedPreferences> prefs = new HashMap<>();
    private final Resources resources = new Resources();

    public Context() {
        services.put(CONNECTIVITY_SERVICE, new android.net.ConnectivityManager());
        services.put(WIFI_SERVICE, new android.net.wifi.WifiManager());
        services.put(DISPLAY_SERVICE, new android.hardware.display.DisplayManager());
        // NSD_SERVICE deliberately absent: EasyConnDiscovery.discoverNsd() then logs
        // "[DISC] NsdManager unavailable" and returns null (loopback can never be an NSD endpoint
        // anyway: EasyConnDiscovery.isUsableBikeIpv4 rejects 127.0.0.1).
    }

    /** Harness hook: override / remove a system service. */
    public void putSystemService(String name, Object service) {
        if (service == null) services.remove(name); else services.put(name, service);
    }

    public Object getSystemService(String name) { return services.get(name); }

    public Context getApplicationContext() { return this; }

    public synchronized SharedPreferences getSharedPreferences(String name, int mode) {
        return prefs.computeIfAbsent(name, n -> new InMemorySharedPreferences());
    }

    public String getString(int resId) {
        String s = dev.zanderp.opencfmoto.R.text(resId);
        return s != null ? s : ("<string 0x" + Integer.toHexString(resId) + ">");
    }

    public Resources getResources() { return resources; }

    public File getExternalFilesDir(String type) { return null; }
}
