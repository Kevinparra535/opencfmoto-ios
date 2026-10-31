// HARNESS STUB (not Android code). BRAND/MODEL/SDK_INT end up in the CLIENT_INFO reply
// (phoneBrand / phoneModel / phoneOsVersion). Defaults = the spec example (control-plane.md §8.4);
// override with -Dharness.build.brand=… -Dharness.build.model=… -Dharness.build.sdk=….
package android.os;

public final class Build {
    private Build() {}
    public static final String BRAND = System.getProperty("harness.build.brand", "samsung");
    public static final String MANUFACTURER = System.getProperty("harness.build.manufacturer", "samsung");
    public static final String MODEL = System.getProperty("harness.build.model", "SM-G991B");

    public static final class VERSION {
        private VERSION() {}
        public static final int SDK_INT = Integer.getInteger("harness.build.sdk", 35);
        public static final String RELEASE = System.getProperty("harness.build.release", "15");
    }
}
