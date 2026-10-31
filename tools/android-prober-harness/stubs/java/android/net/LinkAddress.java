// HARNESS STUB (not Android code).
package android.net;

import java.net.InetAddress;

public class LinkAddress {
    private final InetAddress address;
    private final int prefixLength;
    public LinkAddress(InetAddress address, int prefixLength) { this.address = address; this.prefixLength = prefixLength; }
    public InetAddress getAddress() { return address; }
    public int getPrefixLength() { return prefixLength; }
    @Override public String toString() { return address.getHostAddress() + "/" + prefixLength; }
}
