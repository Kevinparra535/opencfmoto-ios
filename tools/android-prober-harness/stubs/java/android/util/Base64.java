// HARNESS STUB (not Android code). android.util.Base64 semantics on top of java.util.Base64:
// DEFAULT wraps at 76 chars with '\n' and ends with '\n'; NO_WRAP = one line; NO_PADDING, URL_SAFE, CRLF.
// (RsaKeys.kt only uses NO_WRAP, which is plain RFC 4648 with padding.)
package android.util;

public final class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int CRLF = 4;
    public static final int URL_SAFE = 8;
    public static final int NO_CLOSE = 16;

    private Base64() {}

    public static String encodeToString(byte[] input, int flags) {
        java.util.Base64.Encoder enc = (flags & URL_SAFE) != 0 ? java.util.Base64.getUrlEncoder() : java.util.Base64.getEncoder();
        if ((flags & NO_PADDING) != 0) enc = enc.withoutPadding();
        String s = enc.encodeToString(input);
        if ((flags & NO_WRAP) != 0) return s;
        String nl = (flags & CRLF) != 0 ? "\r\n" : "\n";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < s.length(); i += 76) {
            sb.append(s, i, Math.min(s.length(), i + 76)).append(nl);
        }
        return sb.toString();
    }

    public static byte[] encode(byte[] input, int flags) {
        return encodeToString(input, flags).getBytes(java.nio.charset.StandardCharsets.US_ASCII);
    }

    public static byte[] decode(String str, int flags) {
        String clean = str.replaceAll("[\\r\\n\\t ]", "");
        if ((flags & URL_SAFE) != 0) return java.util.Base64.getUrlDecoder().decode(clean);
        return java.util.Base64.getDecoder().decode(clean);
    }

    public static byte[] decode(byte[] input, int flags) {
        return decode(new String(input, java.nio.charset.StandardCharsets.US_ASCII), flags);
    }
}
