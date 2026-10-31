// HARNESS STUB (not Android code). Empty, process-local preferences => every upstream setting
// reads its documented default (no garage bike selected, BALANCED quality, AUTO profile, ...).
package android.content;

import java.util.HashMap;
import java.util.Map;

final class InMemorySharedPreferences implements SharedPreferences {
    private final Map<String, Object> map = new HashMap<>();

    @Override public synchronized Map<String, ?> getAll() { return new HashMap<>(map); }
    @Override public synchronized String getString(String k, String d) { Object v = map.get(k); return v instanceof String ? (String) v : d; }
    @Override public synchronized int getInt(String k, int d) { Object v = map.get(k); return v instanceof Integer ? (Integer) v : d; }
    @Override public synchronized long getLong(String k, long d) { Object v = map.get(k); return v instanceof Long ? (Long) v : d; }
    @Override public synchronized float getFloat(String k, float d) { Object v = map.get(k); return v instanceof Float ? (Float) v : d; }
    @Override public synchronized boolean getBoolean(String k, boolean d) { Object v = map.get(k); return v instanceof Boolean ? (Boolean) v : d; }
    @Override public synchronized boolean contains(String k) { return map.containsKey(k); }

    @Override public Editor edit() {
        final Map<String, Object> pending = new HashMap<>();
        final boolean[] clear = {false};
        final Object REMOVE = new Object();
        return new Editor() {
            public Editor putString(String k, String v) { pending.put(k, v == null ? REMOVE : v); return this; }
            public Editor putInt(String k, int v) { pending.put(k, v); return this; }
            public Editor putLong(String k, long v) { pending.put(k, v); return this; }
            public Editor putFloat(String k, float v) { pending.put(k, v); return this; }
            public Editor putBoolean(String k, boolean v) { pending.put(k, v); return this; }
            public Editor remove(String k) { pending.put(k, REMOVE); return this; }
            public Editor clear() { clear[0] = true; return this; }
            public boolean commit() {
                synchronized (InMemorySharedPreferences.this) {
                    if (clear[0]) map.clear();
                    for (Map.Entry<String, Object> e : pending.entrySet()) {
                        if (e.getValue() == REMOVE) map.remove(e.getKey()); else map.put(e.getKey(), e.getValue());
                    }
                }
                return true;
            }
            public void apply() { commit(); }
        };
    }
}
