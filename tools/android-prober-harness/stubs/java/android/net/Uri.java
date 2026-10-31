// HARNESS STUB (not Android code). Only Uri.Builder (QrData.buildManual) is referenced; never called here.
package android.net;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

public class Uri {
    private final String text;
    private Uri(String text) { this.text = text; }
    public static Uri parse(String s) { return new Uri(s); }
    @Override public String toString() { return text; }

    public static final class Builder {
        private String scheme = "", authority = "", path = "";
        private final StringBuilder query = new StringBuilder();
        public Builder scheme(String s) { scheme = s; return this; }
        public Builder authority(String a) { authority = a; return this; }
        public Builder path(String p) { path = p; return this; }
        public Builder appendPath(String p) { path = path + "/" + p; return this; }
        public Builder appendQueryParameter(String k, String v) {
            if (query.length() > 0) query.append('&');
            query.append(URLEncoder.encode(k, StandardCharsets.UTF_8)).append('=')
                 .append(URLEncoder.encode(v == null ? "" : v, StandardCharsets.UTF_8));
            return this;
        }
        public Uri build() {
            return new Uri(scheme + "://" + authority + path + (query.length() > 0 ? "?" + query : ""));
        }
    }
}
