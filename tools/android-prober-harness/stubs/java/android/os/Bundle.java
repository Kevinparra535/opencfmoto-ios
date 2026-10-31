// HARNESS STUB (not Android code).
package android.os;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

public final class Bundle {
    private final Map<String, Object> map = new LinkedHashMap<>();
    public void putInt(String key, int value) { map.put(key, value); }
    public void putLong(String key, long value) { map.put(key, value); }
    public void putString(String key, String value) { map.put(key, value); }
    public int getInt(String key) { Object v = map.get(key); return v instanceof Integer ? (Integer) v : 0; }
    public boolean containsKey(String key) { return map.containsKey(key); }
    public Set<String> keySet() { return map.keySet(); }
    @Override public String toString() { return "Bundle" + map; }
}
