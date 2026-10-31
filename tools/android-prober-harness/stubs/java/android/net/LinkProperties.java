// HARNESS STUB (not Android code).
package android.net;

import java.net.InetAddress;
import java.util.ArrayList;
import java.util.List;

public class LinkProperties {
    public String getInterfaceName() { return "lo"; }
    public List<LinkAddress> getLinkAddresses() { return new ArrayList<>(); }
    public List<RouteInfo> getRoutes() { return new ArrayList<>(); }
    public List<InetAddress> getDnsServers() { return new ArrayList<>(); }
    @Override public String toString() { return "LinkProperties(harness)"; }
}
