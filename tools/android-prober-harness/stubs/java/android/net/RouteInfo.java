// HARNESS STUB (not Android code).
package android.net;

import java.net.InetAddress;

public class RouteInfo {
    private final InetAddress gateway;
    private final boolean def;
    public RouteInfo(InetAddress gateway, boolean isDefault) { this.gateway = gateway; this.def = isDefault; }
    public boolean isDefaultRoute() { return def; }
    public InetAddress getGateway() { return gateway; }
}
