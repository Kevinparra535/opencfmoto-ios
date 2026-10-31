// HARNESS STUB (not Android code). The harness passes network = null (like the Wi-Fi Direct path
// with gatewayOverride/bindIpOverride), so these are never used for real traffic.
package android.net;

import java.io.IOException;
import java.net.Socket;
import javax.net.SocketFactory;

public class Network {
    public SocketFactory getSocketFactory() { return SocketFactory.getDefault(); }
    public void bindSocket(Socket socket) throws IOException { }
    @Override public String toString() { return "Network(harness)"; }
}
