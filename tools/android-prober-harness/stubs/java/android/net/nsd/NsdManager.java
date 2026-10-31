// HARNESS STUB (not Android code). Not registered as a system service (see Context), so
// EasyConnDiscovery.discoverNsd() takes its own "NsdManager unavailable" branch.
package android.net.nsd;

public class NsdManager {
    public static final int PROTOCOL_DNS_SD = 1;

    public interface DiscoveryListener {
        void onStartDiscoveryFailed(String serviceType, int errorCode);
        void onStopDiscoveryFailed(String serviceType, int errorCode);
        void onDiscoveryStarted(String serviceType);
        void onDiscoveryStopped(String serviceType);
        void onServiceFound(NsdServiceInfo serviceInfo);
        void onServiceLost(NsdServiceInfo serviceInfo);
    }

    public interface ResolveListener {
        void onResolveFailed(NsdServiceInfo serviceInfo, int errorCode);
        void onServiceResolved(NsdServiceInfo serviceInfo);
    }

    public void discoverServices(String serviceType, int protocolType, DiscoveryListener listener) {
        listener.onStartDiscoveryFailed(serviceType, 0);
    }
    public void resolveService(NsdServiceInfo serviceInfo, ResolveListener listener) {
        listener.onResolveFailed(serviceInfo, 0);
    }
    public void stopServiceDiscovery(DiscoveryListener listener) { }
}
