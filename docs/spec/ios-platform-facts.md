# iOS platform facts: fact-check for the OpenCfMoto iOS design

Research date: 2026-10-31. Baseline: deployment target iOS 17.0 (`project.yml`), current shipping release
iOS 27.x. This note covers questions (a)–(k) from the architecture review. It records what Apple documents
or what Apple engineers have said, labels everything else, and ends with design decisions.

**Update 2026-11-03** (research for keeping the dash map live while the iPhone is locked; it feeds the
Phase 0 diagnostics build): (d) background hardware encoding raised to High on an Apple Media Engineer's
statement, background GPU for `BGContinuedProcessingTask` limited to M3 iPads, the software-encoder probe;
(e) the When-In-Use indicator, the CPU-monitor limits, Wi-Fi while locked, the activity type; (f) the
`screen-capture` mode; (i) TestFlight upload validation; device questions 1–2 and design recommendations 2
and 4. The owner's Phase 0 log answers the device questions; its results go here once known.

**Confidence scale**

- **High**: an Apple document, technote, WWDC session, or an Apple DTS / Apple engineer forum answer says
  so directly.
- **Medium**: strong indirect evidence. This means consistent behavior in widely used open-source code,
  several independent field reports, or a direct inference from Apple documentation.
- **Low**: anecdotal, conflicting, or untested.

**Method and gaps.** Apple documentation was fetched as Markdown from `developer.apple.com/documentation/<path>.md`,
with availability taken from the docs JSON. Developer Forums threads and open-source code were read directly.
The research sandbox could not reach these hosts: `www.apple.com` (EULA), `support.apple.com`,
`communities.apple.com`, `signal.org`, `webrtc.googlesource.com`, `forasoft.com` and `tencentcloud.com`.
Anything attributed to them comes from search-engine excerpts only and is marked that way.

**Note on the brief.** TN3135 is *Low-level networking on watchOS* and does not apply to iPhone. The relevant
Apple material is TN3179 (local network privacy), TN3111 (iOS Wi-Fi API overview), TN3151 (choosing a
networking API) and Quinn "The Eskimo!"'s *Extra-ordinary Networking* forum series.

---

## Answers at a glance

| # | Question | Short answer | Confidence |
| --- | --- | --- | --- |
| a | Hotspot entitlement with a free Personal Team? | **No.** Hotspot and Access WiFi Information are paid-program only. App Groups and Background Modes are available free. | High |
| a | `joinOnce` semantics | Kept only while the app is in the foreground. Torn down after more than 15 s in the background, on device sleep, on crash or quit, or when Wi-Fi switches. Unusable for a locked phone. | High |
| a | Join a Wi-Fi Direct "DIRECT-xx" group owner? | Yes. iOS joins it as an ordinary WPA2-PSK network (legacy client). No P2P API is involved. | Medium |
| b | Does internet fall back to cellular automatically? | **Usually.** DTS says the default route typically stays on cellular for a no-internet network. It is not guaranteed, and DTS says to test each iOS version against each accessory. | Medium |
| b | `requiredInterfaceType = .cellular` while Wi-Fi is up | Yes. This is the supported way to force a connection onto cellular (Network framework, or `IP_BOUND_IF` in BSD sockets). | High |
| b | URLSession equivalent | **None.** You can prohibit cellular, but you cannot force it. | High |
| c | What triggers the Local Network alert? | Outgoing TCP to the dash (192.168.x.1:10930), Bonjour browse or resolve, and `.local` lookups. Listening for and accepting inbound TCP does **not** trigger it. | High |
| c | Ports below 1024 | Allowed on iOS. The 109xx ports have no issue. | High |
| d | Hardware H.264 encoding in the background | **Not available.** An Apple Media Engineer: encoding resources are given up in the background (forum 672056). Sessions come back invalid (`kVTInvalidSessionErr` −12903); widely used code (WebRTC, FFmpeg) handles exactly that. | High (unavailable) / Medium (exact codes) |
| d | Software H.264 encoder on iOS | None is documented (still in Nov 2026), and no device report says either way. The Phase 0 diagnostics build probes it on the owner's iPhone; otherwise bundle one (OpenH264). | Low |
| d | GPU in the background | Not allowed. Metal returns `notPermitted`, OpenGL ES terminates the app, `MKMapSnapshotter` waits for the foreground. `BGContinuedProcessingTask` GPU access exists only on iPads with M3 or newer, never on an iPhone. CPU Core Graphics is fine. | High |
| e | Location background mode keeps the process running | Yes, while standard location updates keep running. Disable automatic pausing. | High |
| e | Wi-Fi association while locked | **Not guaranteed.** iOS can leave Wi-Fi when the device sleeps after screen lock; DTS: the system aims to sleep the whole application processor unless something like music playback prevents it, and there is no API to stop that. | Low (device test) |
| f | Broadcast-extension memory limit | About 50 MB. This is community-documented, not Apple-documented. | Medium |
| f | ReplayKit status | **Deprecated in the iOS 27 SDK.** ScreenCaptureKit, with the `screen-capture` background mode, replaces it on iOS 27+. | High |
| g | AVRCP buttons | Delivered only to the **Now Playing** app, which needs a non-mixable session that is actually playing. | High |
| h | QR scanning | `DataScannerViewController` (needs A12, which every iOS 17 iPhone has), with `AVCaptureMetadataOutput` as fallback. | High |
| i | (A)GPL on the App Store | A copyright holder can publish. A port carrying third-party AGPL code needs upstream permission to be safe. | Medium (legal) |
| j | Default gateway | `NWPath.gateways` (public, iOS 13+). Routing sockets and `sysctl` route dumps are unsupported. | High / Medium |
| k | Keeping the screen on; thermal state | `isIdleTimerDisabled` (Apple names mapping apps as a valid use) and `ProcessInfo.thermalState`. | High |

---

## a) NEHotspotConfiguration: joining the dash access point

### Answer

**Entitlement and account type.** The entitlement is `com.apple.developer.networking.HotspotConfiguration`
(Xcode capability *Hotspot Configuration*). Apple DTS says it "does not need specific approval from Apple to
use". Like every iOS entitlement, it is restricted, which means a provisioning profile must authorize it.
DTS adds: "Any (paid) developer account can use it."

Apple's *Supported capabilities (iOS)* table has three columns: ADP (paid), ADEP (enterprise) and
*Apple Developer* (free). **Hotspot** and **Access WiFi information** are ticked only for ADP and ADEP.
**Free Personal Teams cannot use either.** See (i) for the full list.

**`joinOnce = true`, documented semantics.** The hotspot "remains configured and connected only as long as
the app that configured it is running in the foreground". It is disconnected and its configuration removed
when any of these happens:

- the app stays in the background for more than 15 s
- the device sleeps
- the app crashes, quits or is uninstalled
- the app connects the device to a different Wi-Fi network
- the user connects the device to a different Wi-Fi network

So `joinOnce` cannot survive a phone locked in a pocket.

TN3111 recommends `joinOnce = true` for temporarily joining an accessory that has its own network. In
September 2026, DTS (thread 848895) again recommended `joinOnce = true` for a no-internet accessory network.
The reason given: a persistent configuration makes iOS treat the network "like it would any other
infrastructure Wi-Fi network". iOS "could potentially end up wasting time joining this network, only to find
that it doesn't connect to the Internet, and then leave it and trying the other saved Wi-Fi configurations."

**`joinOnce = false` (persistent).** This behaves like joining in Settings and survives backgrounding and
sleep. The app can remove only its own configurations, with `removeConfiguration(forSSID:)`, and iOS removes
them all when the app is uninstalled. `lifeTimeInDays` accepts 1–365. If it is unset, the configuration
never expires.

A field report on iOS 26.x (thread 848895) is directly on point:

- Setup: `joinOnce = false`, WPA2, and the accessory's DHCP hands out itself as router and DNS.
- About 28 s into a long cellular upload, while the accessory link was nearly idle, Wi-Fi dropped for 3 s.
  The phone then rejoined a saved network that had internet.
- Occasionally iOS asked whether to stay connected without internet.
- It was never seen while the accessory link was busy.
- DTS did not offer a way to stay on the network.

**`apply(_:)` behavior** (Apple docs):

- The user is prompted for every new or updated configuration.
- iOS joins only if the network is nearby.
- The completion handler means the configuration was applied, **not that the device joined**. Verify with
  `NEHotspotNetwork.fetchCurrent`. Joining doesn't mean TCP/IP is ready either, so use an API that waits for
  connectivity, such as `NWConnection`.
- Apply only while the app is in the foreground. Otherwise you get `applicationIsNotInForeground`. DTS:
  "trying to apply a Wi-Fi configuration when your app is in the background isn't going to end well".

Field gotchas:

- A `nil` error can come back even with a wrong password.
- Completion takes about 4–10 s.
- `.internal` (8) is the common transient failure. DTS: it "means that something went wrong in some sort of
  expected way". Retry, or remove the configuration and re-apply it.
- DTS considers an unexplained `.userDenied` (7) a bug.

**A WPA2 network without internet.** There's no API flag for this, and the join prompt is the same. The
system's own evaluation (DTS, *The iOS Wi-Fi Lifecycle*):

- An auto-joined network must have a "viable IP configuration" (address, subnet mask and **router** from
  DHCP) and must not be captive.
- The captive test is an HTTP request to Apple. "If the request fails, the system assumes it's not captive."
- iOS doesn't do the viable-IP evaluation for networks the user joins manually.

The dash's DHCP does give a router (192.168.0.1, or 192.168.49.1 on Wi-Fi Direct dashes), so the dash
network can become the default route. The consequences are in (b).

**Wi-Fi Direct "DIRECT-xx" group owner.** Yes, iOS can join it. A P2P group owner runs a WPA2-PSK access
point for legacy (non-P2P) clients, and iPhones join such networks like any other WPA2 network:

- HP printers' `DIRECT-xx-…` networks are routinely joined from iPhone Settings (HP community).
- `NEHotspotConfiguration(ssid:passphrase:isWEP:false)` treats a `DIRECT-` SSID as an ordinary SSID.
- The Android port confirmed that a station-style join worked unchanged on the CFDL26 group owner
  (`DIRECT-CF-CFMOTO-…`, gateway 192.168.49.1; `open-cfmoto/docs/01-REVERSE-ENGINEERING.md` §7.1).

iOS has no API to *create* or *negotiate* Wi-Fi Direct groups, and none is needed here. Caveats:

- A group that isn't persistent can change its passphrase, so always use the credentials from the current QR
  code.
- A group owner may tear down an idle group.
- Wi-Fi Aware (iOS 26+, iPhone 12+), which DTS suggests for new accessories, needs Wi-Fi Aware support in the
  dash firmware. The dash has none, so it doesn't apply.

**AccessorySetupKit (iOS 18+)** can discover Wi-Fi accessories by SSID or SSID prefix and skips some
alerts. But `joinAccessoryHotspot` implicitly uses `joinOnce = true`, and an Apple engineer confirmed it
"is not possible" to keep `joinOnce = false` (thread 775955). That makes it unsuitable for riding with the
phone locked.

**`NEHotspotNetwork.fetchCurrent`** (iOS 14+) returns SSID, BSSID and security type only. It requires the
`com.apple.developer.networking.wifi-info` entitlement (otherwise it returns `nil`) **and** at least one of:

- precise-location authorization
- **the app configured the current network with `NEHotspotConfiguration`**
- an active VPN configuration
- an active `NEDNSSettingsManager` configuration

Our app meets the second condition, so it doesn't need location permission for this call. Free Personal Team
builds can't get the entitlement, so they can never read the SSID.

### Errors to handle (`NEHotspotConfigurationErrorDomain`)

Raw values are from the SDK header as remembered. The documentation lists the cases but not the numbers, so
verify against `NEHotspotConfigurationManager.h`. Values 7 and 8 are confirmed by DTS.

| Value | Case | Handling |
| --- | --- | --- |
| 0 | `invalid` | Bug in our configuration; log it |
| 1 | `invalidSSID` | QR parse problem; offer manual entry |
| 2 | `invalidWPAPassphrase` | Must be 8–63 chars; offer manual entry |
| 3, 4, 5, 6 | WEP, EAP, HS2.0 errors | Shouldn't happen |
| 7 | `userDenied` | User tapped Cancel. Show the manual join path |
| 8 | `internal` | Transient. Wait, `removeConfiguration`, retry once |
| 9 | `pending` | Another apply is in progress. Wait |
| 10 | `systemConfiguration` | Same SSID is managed by MDM or a carrier profile |
| 11 | `unknown` | Retry once, then use the manual path |
| 12 | `joinOnceNotSupported` | EAP only |
| 13 | `alreadyAssociated` | **Success.** Already on the network |
| 14 | `applicationIsNotInForeground` | Defer until the app is active |
| 15 | `invalidSSIDPrefix` | Only for prefix configurations |
| 16 | `userUnauthorized` | Not documented. Treat like `userDenied` |
| 17 | `systemDenied` | Not documented (for example, restrictions). Use the manual path |

### Practical guidance

```swift
import NetworkExtension

func joinDash(ssid: String, pass: String) async -> Bool {
    let cfg = NEHotspotConfiguration(ssid: ssid, passphrase: pass, isWEP: false)
    cfg.joinOnce = false            // needed to survive lock/background (see trade-off above)
    do {
        try await NEHotspotConfigurationManager.shared.apply(cfg)   // foreground only
    } catch let e as NSError where e.domain == NEHotspotConfigurationErrorDomain {
        switch NEHotspotConfigurationError(rawValue: e.code) {
        case .alreadyAssociated?: break
        case .userDenied?, .userUnauthorized?, .systemDenied?: return false   // manual-join UI
        default: return false       // retry policy: remove + re-apply once
        }
    } catch { return false }
    // "Applied" ≠ "joined": now wait for a Wi-Fi path whose gateway is in the dash subnet,
    // optionally confirm SSID via NEHotspotNetwork.fetchCurrent(), then start listeners + probe.
    return true
}
```

- Check first whether you're already on the dash network (gateway or SSID). Call `apply` only if you aren't,
  because each new or updated configuration prompts the user.
- Add a *Forget bike Wi-Fi* action that calls `removeConfiguration(forSSID:)`.
- Watch with `NWPathMonitor` for iOS hopping to another network mid-ride. If it does, re-apply when the app
  is next in the foreground, or post a local notification asking the rider to reconnect.

### Sources

- joinOnce: https://developer.apple.com/documentation/networkextension/nehotspotconfiguration/joinonce
- Manager: https://developer.apple.com/documentation/networkextension/nehotspotconfigurationmanager
- apply: https://developer.apple.com/documentation/networkextension/nehotspotconfigurationmanager/apply(_:completionhandler:)
- lifeTimeInDays: https://developer.apple.com/documentation/networkextension/nehotspotconfiguration/lifetimeindays
- Errors: https://developer.apple.com/documentation/networkextension/nehotspotconfigurationerror
- fetchCurrent: https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchcurrent(completionhandler:)
- Entitlements: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.hotspotconfiguration
  and https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.wifi-info
- Capability table: https://developer.apple.com/help/account/reference/supported-capabilities-ios
- DTS, entitlement needs no approval, "any (paid) developer account": https://developer.apple.com/forums/thread/703017
- DTS 2026, joinOnce for accessories, plus the iOS 26 field report: https://developer.apple.com/forums/thread/848895
- DTS, *The iOS Wi-Fi Lifecycle*: https://developer.apple.com/forums/thread/734361
- DTS, *Working with a Wi-Fi Accessory*: https://developer.apple.com/forums/thread/734344
- DTS, meaning of `.internal` and `.userDenied`, no background apply: https://developer.apple.com/forums/thread/786689
- `nil` error despite failure (community): https://developer.apple.com/forums/thread/765186
- TN3111: https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview
- AccessorySetupKit: https://developer.apple.com/documentation/accessorysetupkit/discovering-and-configuring-accessories
  and the joinOnce limit: https://developer.apple.com/forums/thread/775955
- Joining HP `DIRECT-` networks from iPhone (community): https://h30434.www3.hp.com/t5/Printers-Archive-Read-Only/Wi-Fi-Direct-Password/m-p/7691391

---

## b) Internet over cellular while Wi-Fi is the dash network

### Answer

**Automatic fallback is typical, not guaranteed.** DTS (Quinn, thread 666276):

> When you manually join a Wi-Fi network that doesn't have access to the wider Internet, iOS will typically
> leave the default route set to WWAN and thus apps that don't explicitly target the Wi-Fi will continue to
> run over WWAN. However … it's not uncommon for an accessory to publish a Wi-Fi network that pretends to
> provide access to the wider Internet. Such fakery can cause iOS to switch the default route to the
> accessory's network … Except that modern versions of iOS do their best to detect this and route those
> app's connections over WWAN. … the only way to be sure of the behaviour is to test a specific iOS version
> against a specific accessory's network.

*Working with a Wi-Fi Accessory* adds: if the accessory network becomes the default route, "most network
connections from iOS will be routed to your accessory … those connections will fail. That includes
connections made by your own app." The workaround is to bind connections to WWAN, which "only works if the
user *has* WWAN".

The dash is the risky kind: its DHCP gives a router, and the captive probe fails, which iOS treats as "not
captive". Wi-Fi Assist doesn't help. Apple describes it as switching to cellular when the Wi-Fi *connection*
is poor, not when the link is good but has no internet (support.apple.com, via search excerpt).

**Forcing cellular works.** DTS (thread 655183): "If you're using Network framework, you can force a
connection to run over a specific interface type using the `requiredInterfaceType` property." The cellular
interface stays up while Wi-Fi is the default route. DTS: "the WWAN interface is still available, it's just
not the default route."

The thread 848895 setup (iOS 26.x) is exactly our architecture, and its cellular uploads worked:

- accessory traffic: `NWConnection` with `prohibitedInterfaceTypes = [.cellular]`
- server traffic: `requiredInterfaceType = .cellular`

In BSD sockets the equivalent is `IP_BOUND_IF` with the cellular interface index.

Failure modes, reported as an unsatisfied path:

- no SIM, Airplane Mode, or cellular data off
- **the user turned off Cellular Data for our app**: `NWPath.UnsatisfiedReason.cellularDenied`
- data roaming disabled abroad
- Low Data Mode, but only if you also set `prohibitConstrainedPaths`

**URLSession has no equivalent.** DTS, *Running an HTTP Request over WWAN*: "`URLSessionConfiguration` has
a property, `allowsCellularAccess` … However, there's no opposite of that, a way to *force* requests to run
over WWAN." Options:

1. Network framework with a small HTTP/1.1 client. TN3151 mentions building "a simplistic HTTP client using
   `CFHTTPMessage` on top of a TCP API". Use `NWProtocolTLS` for HTTPS. Tile and route GETs are simple.
2. Multipath TCP. This needs the server to support MPTCP and the paid-only Multipath entitlement, so it
   isn't viable.
3. *(Design idea, not Apple guidance; validate on a device.)* Run an in-process loopback HTTP CONNECT or
   SOCKSv5 proxy whose upstream `NWConnection`s require `.cellular`. Point URLSession at it with
   `URLSessionConfiguration.proxyConfigurations` (iOS 17+, `ProxyConfiguration(httpCONNECTProxy:tlsOptions:)`
   or `ProxyConfiguration(socksv5Proxy:)`). TLS stays end-to-end and URLSession-based code (caches,
   decoders) keeps working. Loopback is not a local-network address under TN3179.

**MapKit, WKWebView and system services** follow the system's routing and cannot be bound. So MapKit tiles
in the phone UI usually load, because the default route usually stays on cellular, but that isn't
guaranteed. Two further limits:

- `MKMapSnapshotter` "delivers the final image to your app only when it's running in the foreground". It
  can't feed the dash in the background (see d).
- Without the paid program, "you can use the MapKit framework but you can't provide routing directions".

**Dash traffic should be bound to Wi-Fi.** The subnet route sends traffic to 192.168.0.0/24 over Wi-Fi
regardless of the default route. DTS: "Any traffic destined for that network will be routed directly to
that interface, ignoring the default route." Binding (`requiredInterfaceType = .wifi`) still makes the
intent explicit and makes failures fast when Wi-Fi is gone. A field report says unbound local requests
failed while cellular was preferred (thread 655183, WKWebView case).

### Practical guidance

```swift
import Network

func internetParams() -> NWParameters {           // map tiles, routing, geocoding while on the dash
    let p = NWParameters(tls: NWProtocolTLS.Options())
    p.requiredInterfaceType = .cellular            // or prohibitedInterfaceTypes = [.wifi]
    return p
}
func dashParams() -> NWParameters {               // probe to :10930 and the listeners
    let p = NWParameters.tcp
    p.requiredInterfaceType = .wifi
    p.allowLocalEndpointReuse = true
    return p
}
// On .waiting: inspect connection.currentPath?.unsatisfiedReason:
//   .cellularDenied  -> ask the user to enable Cellular Data for the app
//   .localNetworkDenied -> Local Network privacy (see c)
```

- Use the cellular-bound policy **only while the dash link is active**. Otherwise use default routing, so
  route planning at home over normal Wi-Fi works.
- Respect the usage policies of the free OSM-based services (OSM tiles, Nominatim, the OSRM demo, Valhalla,
  Photon). The Android app sends an identifying User-Agent and spaces requests. App Review guideline 5.2.2
  also requires permission under each service's terms.

### Sources

- DTS, default route stays on WWAN: https://developer.apple.com/forums/thread/666276
- DTS, `requiredInterfaceType`: https://developer.apple.com/forums/thread/655183
- *Running an HTTP Request over WWAN*: https://developer.apple.com/forums/thread/734343
- *Network Interface Techniques*: https://developer.apple.com/forums/thread/734359
- *Network Interface Concepts*: https://developer.apple.com/forums/thread/734293
- *Working with a Wi-Fi Accessory*: https://developer.apple.com/forums/thread/734344
- Architecture that works on iOS 26: https://developer.apple.com/forums/thread/848895
- requiredInterfaceType: https://developer.apple.com/documentation/network/nwparameters/requiredinterfacetype
- UnsatisfiedReason: https://developer.apple.com/documentation/network/nwpath/unsatisfiedreason-swift.enum
- proxyConfigurations: https://developer.apple.com/documentation/foundation/urlsessionconfiguration/proxyconfigurations
- ProxyConfiguration: https://developer.apple.com/documentation/network/proxyconfiguration
- TN3151: https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api
- MKMapSnapshotter: https://developer.apple.com/documentation/mapkit/mkmapsnapshotter/start(with:completionhandler:)
- MapKit routing for free accounts (capability table notes): https://developer.apple.com/help/account/reference/supported-capabilities-ios
- Wi-Fi Assist (search excerpt): https://support.apple.com/102228

---

## c) Local Network privacy, listeners and ports

### Answer (TN3179, updated 2026-10-06)

**What triggers the alert.** The first *local network operation*. Our case:

| Operation | Needs local network access? |
| --- | --- |
| Outgoing TCP connect to 192.168.0.1 / 192.168.49.1 (`:10930` probe) | **Yes** |
| Listening for and accepting incoming TCP (the dash connecting back to 10920–10922) | **No** |
| Sending, or connecting, a UDP socket to a local address | Yes |
| Receiving incoming UDP unicast | No |
| Bonjour browse, resolve or register (`_EasyConn._tcp`) | Yes |
| Resolving a `.local` name | Yes |

The dash only connects back after our probe, so in practice the alert gates the whole session.

**Required keys.**

- `NSLocalNetworkUsageDescription` in the **app's** `Info.plist`.
- `NSBonjourServices` = `[_EasyConn._tcp]` if we browse or resolve. The entry must match the type we browse.
- The **multicast entitlement is not needed**. It's only for raw multicast or broadcast traffic, arbitrary
  Bonjour types, or browsing all types.
- TN3179: "If your app has app extensions, add the `NSLocalNetworkUsageDescription` and `NSBonjourServices`
  properties to the app's `Info.plist`, not to the app extension's."

**`NWListener` doesn't need Bonjour advertising.** The `service` property is optional, and registering a
service would itself be a local network operation.

**Before the user answers.** "It may deny the operation immediately, before the user has responded to the
alert … use an API that supports waiting for connectivity, like Network framework." An `NWConnection` enters
`.waiting` with `currentPath.unsatisfiedReason == .localNetworkDenied` (iOS 14.2+) and **retries
automatically** once access is granted. If access is revoked later, open connections close.

There is no API to query the state (FB8711182). Detect it from the waiting state, or from Bonjour's
`kDNSServiceErr_PolicyDenied` (−65570).

**In the background.** "If an iOS app is in the background and performs a local network operation while
its Local Network privilege is undetermined, the system denies that operation without presenting the local
network alert. The system doesn't record that decision." App extensions "share the Local Network privilege
state of their container app", and extension types assumed to run in the background behave the same way.
So obtain the permission in the foreground during onboarding. TN3179 shows triggering the alert by
connecting a UDP socket to a local address.

**Other TN3179 points.**

- The Simulator doesn't support local network privacy, so test on a device.
- An iOS 18 bug where the privacy state got out of sync was fixed in iOS 18.6.
- To reset the state, delete the app or use *Reset Location & Privacy*.
- **Don't assume `en0` is Wi-Fi** (see j).

**Ports.** DTS: "On iOS the traditional UNIX privileged port restrictions were disabled before the first
iOS SDK." Ports below 1024 are bindable, and 10920–10922 are fine. The port namespace is **device-wide**,
though. If another app (for example the official vendor app, while running) holds 10920–10922, our
`NWListener` fails with `EADDRINUSE`. Detect this and tell the rider. Set `allowLocalEndpointReuse` to
rebind quickly after a restart.

**Listener in the background.** While our process keeps running (see e), listeners keep accepting. If the
app is ever suspended, TN2277 explains that the kernel may reclaim a listening socket, and recommends
closing listeners when going to the background unless the app keeps running. If you'll be suspended, stop
the listeners. Otherwise keep them up.

### Practical guidance

```swift
let params = NWParameters.tcp
params.requiredInterfaceType = .wifi        // DTS: bind listeners to the interface, not to an IP
params.allowLocalEndpointReuse = true
let ctrl = try NWListener(using: params, on: 10922)   // likewise 10921, 10920 — start BEFORE the probe
```

### Sources

- TN3179: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- WWDC20 10110: https://developer.apple.com/videos/play/wwdc2020/10110/
- Keys: https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription
  and https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices
- DTS, privileged ports: https://developer.apple.com/forums/thread/104965
- DTS, binding listeners to an interface: https://developer.apple.com/forums/thread/734295
- TN2277 (archived): https://developer.apple.com/library/archive/technotes/tn2277/_index.html

---

## d) VideoToolbox, GPU and drawing in the background

### Answer

**Hardware H.264 encoding in the background.** *Updated 2026-11-03:* an Apple Media Engineer answered it
for AVAssetWriter, which encodes with the same hardware (forum 672056, 2021): "This is expected behavior.
The asset writer must give up encoding resources when your app goes into the background, and there is no
way to reliably pick up where you left off once that happens." Widely deployed code all treats the iOS
hardware encoder as unavailable or invalidated around backgrounding:

- **WebRTC** (current, `RTCVideoEncoderH264.mm`): on `kVTInvalidSessionErr`, "This error occurs when
  entering foreground after backgrounding the app". The session is reset. The 2016 Chromium change that
  introduced this says: "When the iOS application is not in the foreground, the hardware encoder and decoder
  become invalidated." The old code skipped encoding while inactive: "the hardware encoder has been
  invalidated by the OS".
- **FFmpeg** (master, `videotoolboxenc.c`): "On iOS, the VT session is invalidated when the APP switches
  from foreground to background and vice versa." It re-creates the session on `kVTInvalidSessionErr`.
- **Linphone and GStreamer**: decoders hit −12903 after background.
- **SmartDeviceLink iOS** (phone-to-car-head-unit projection, the same use case as ours): the encoder's pixel
  buffer gets invalidated in the background, and the encoder is recreated on return to the foreground.

Nothing suggests that the `location` background mode changes this. Expect:

| Code | Constant | Meaning |
| --- | --- | --- |
| −12903 | `kVTInvalidSessionErr` | The session was invalidated |
| −12915 | `kVTVideoEncoderNotAvailableNowErr` | The encoder is unavailable, for example on create |
| −12912 | `kVTVideoEncoderMalfunctionErr` | Encoder malfunction |
| −12902 | `kVTParameterErr` | A generic parameter error, not a background signal |

**Confidence: high** that hardware encoding is unavailable in the background (the Apple statement above);
medium for the exact codes (via AVAssetWriter: `AVError` −11847 with the underlying −16121). Device test:
open question 2.

**Is there a software encoder?** No software H.264 encoder on iOS is documented (still true in Nov 2026).

- Since the iOS 17.4 SDK, `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder` and
  `…_RequireHardwareAcceleratedVideoEncoder` exist on iOS. Setting Enable to `false` is documented as the way
  "to specifically prevent hardware encoding".
- Whether iOS then provides a software H.264 encoder is undocumented. The community view is that iOS
  H.264/HEVC encoders "are always hardware accelerated" (forum 751291, not an Apple engineer).
- **Test on a device:** create a session with Enable = `false` and read
  `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder`.
- *Added 2026-11-03:* the probe needs three more things. Dump `VTCopyVideoEncoderList` and try any `avc1`
  `EncoderID` not marked hardware (the list alone settles nothing: one report saw no
  `IsHardwareAccelerated` flag even for the hardware encoder). Create the session while still in the
  foreground (at `.inactive`), not only after `didEnterBackground`. And do not treat an unanswered
  `UsingHardware…` as hardware: test it with a real encode (the property can fail with −12900 on some
  session types, forum 751291). The Phase 0 diagnostics build does exactly this and logs each step
  (`[vt-list]`, `[bg] pre-warm vt-sw …`, `[bg] try vt-sw …`; media-video.md §15.3a).
- Plan for a bundled encoder. **OpenH264** (BSD-2-Clause, Constrained Baseline) is preferred over x264
  (GPL-2.0-or-later). x264 is license-compatible with AGPL but adds copyright holders, which hurts App Store
  options (see i). H.264 patent licensing for a self-built encoder is the distributor's responsibility. Cisco's
  royalty coverage applies only to its own binary downloads, which iOS can't load (guideline 2.5.2).

**Low-latency mode.** `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` (iOS 14.5+) is H.264 only
and hardware only. It means no B-frames and an infinite GOP. WWDC21 says Constrained Baseline and
Constrained High are supported, but the current reference page says "Only High profiles". Use it only after
verifying that the dash decodes the output. Otherwise use a normal real-time session with
`kVTProfileLevel_H264_Baseline_AutoLevel` or `…ConstrainedBaseline_AutoLevel` (iOS 15+).

**GPU and rendering restrictions in the background (all high confidence).**

| API | Background behavior |
| --- | --- |
| Metal | "iOS and tvOS restrict a background app's access to the GPU". New command buffers fail with `MTLCommandBufferError.Code.notPermitted`. |
| OpenGL ES | "An OpenGL ES app is terminated if it attempts to execute OpenGL ES commands on the graphics hardware" while in the background. |
| Core Image | GPU-backed. `useSoftwareRenderer` "has no effect if the platform does not support OpenCL", and iOS has no OpenCL. Treat Core Image as GPU-only and keep it out of the dash path. |
| `MKMapSnapshotter` | Delivers images only in the foreground. |
| `BGContinuedProcessingTask` (iOS 26) | *Updated 2026-11-03:* background GPU access exists, but DTS says it is supported only on "iPads with M3 or newer" and "not supported on any iPhone" (forum 797538), so it can never apply to this app. The task is meant for finite, user-started jobs with a Live Activity showing progress, and the user can cancel it; it doesn't fit a ride-long stream either. |
| Picture in Picture | *Added 2026-11-03:* no exception: GPU submission is revoked about 8 s after backgrounding even while the app feeds an active PiP window (iOS 27 report, OcPlayer PR #71); only a CPU compositing path fixed the frozen picture. |

**CPU drawing is fine.** Core Graphics bitmap contexts, Core Text and Accelerate/vImage run on the CPU. No
document restricts them in the background. The limits that do apply are the system's resource limits:
`EXC_RESOURCE` with `CPU`/`CPU_FATAL` ("used too much CPU over a short period") and `WAKEUPS`. Keep the
background frame rate low and batch the work.

### Practical guidance

```swift
// Real-time Baseline session (foreground path)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 15 as CFNumber)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 1_200_000 as CFNumber)
// On -12903 / -12915 / -12912: drop the session; when UIApplication becomes active, recreate it and
// encode the next frame with kVTEncodeFrameOptionKey_ForceKeyFrame = true (the dash needs an IDR).
```

- Render with Core Graphics into IOSurface-backed `CVPixelBuffer`s from a `CVPixelBufferPool`, in 32BGRA.
- For the software encoder, convert BGRA to NV12/I420 with vImage on the CPU.
- In the background, never touch Metal, Core Image, `UIView` snapshots or MapKit.

### Sources

- WebRTC encoder (mirror of upstream): https://github.com/webrtc-sdk/webrtc/blob/m125_release/sdk/objc/components/video_codec/RTCVideoEncoderH264.mm
- 2016 Chromium review: https://codereview.webrtc.org/1732953003
- FFmpeg: https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/videotoolboxenc.c
  and the patch: https://www.ffmpeg.org/pipermail/ffmpeg-devel/2018-June/231197.html
- Linphone: https://gitlab.linphone.org/BC/public/mediastreamer2/blob/a3ef55cdb23f59600fe62d86f927d15754f5effd/src/videofilters/videotoolbox.c
- GStreamer: https://gitlab.freedesktop.org/gstreamer/gst-plugins-bad/-/issues/288
- SDL: https://github.com/smartdevicelink/sdl_ios/issues/1540
- Apple Media Engineer, encoding resources given up in the background: https://developer.apple.com/forums/thread/672056
- DTS, background GPU only on M3 iPads: https://developer.apple.com/forums/thread/797538
- Encoder specification keys: https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_enablehardwareacceleratedvideoencoder
  and https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_requirehardwareacceleratedvideoencoder
- Low latency: https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_enablelowlatencyratecontrol
  and WWDC21 10158: https://developer.apple.com/videos/play/wwdc2021/10158/
- Community, "always hardware": https://developer.apple.com/forums/thread/751291
- Metal: https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background
- OpenGL ES: https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/OpenGLES_ProgrammingGuide/ImplementingaMultitasking-awareOpenGLESApplication/ImplementingaMultitasking-awareOpenGLESApplication.html
- Core Image: https://developer.apple.com/documentation/coreimage/cicontextoption/usesoftwarerenderer
- BGContinuedProcessingTask: https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados
- EXC_RESOURCE: https://developer.apple.com/documentation/xcode/exc_resource

---

## e) Background execution during a ride

### Answer

**The `location` background mode keeps the process running.** Apple (`allowsBackgroundLocationUpdates`):
"When the value of this property is `true` and you start location updates while the app is in the
foreground, Core Location configures the system to keep the app running to receive continuous background
location updates … Updates continue even if the app subsequently enters the background."

While the app runs, sockets, `NWListener`, `NWConnection`, Dispatch timers and queues keep working.
Requirements and pitfalls:

- Declare `UIBackgroundModes` `location`. Setting the property to `true` without it "is a fatal error".
- Start updates **in the foreground**.
- **When-In-Use authorization is enough**. The system shows the blue background-location indicator. Always
  authorization is needed only to be relaunched by region monitoring or significant-change updates.
  *Confirmed 2026-11-03:* `showsBackgroundLocationIndicator` "affects only apps that received Always
  authorization … For apps with When In Use authorization, the system changes the appearance of the status
  bar when the app uses location services in the background."
- **Set `allowsBackgroundLocationUpdates`, then start updates in the foreground** — the only order Apple
  documents. When updates already run (for example for a preview), flipping the flag on them is
  undocumented: restart them in the foreground instead (the app does since the Phase 0 build, log line
  `GPS restarted with background updates …`).
- Set `pausesLocationUpdatesAutomatically = false`. It defaults to `true`, and a pause stops updates, so the
  app gets suspended at long stops. With When-In-Use, a pause "ends access to location changes until the app
  launches again".
- Set `activityType = .automotiveNavigation`. Apple notes it "might cause the system to pause location
  updates when the vehicle doesn't move for an extended period of time", which the line above prevents.
  Keep it for roads; Apple's `.otherNavigation` is the literal category for "off-road vehicles" (neither
  changes the keep-alive).
- The iOS 17 API (`CLBackgroundActivitySession` with `CLLocationUpdate.liveUpdates`) can suspend updates while
  stationary (`isStationary`). For a keep-alive, use the classic `CLLocationManager`.
- **"Indefinitely" isn't guaranteed.** "The system can terminate apps at any time to free up memory or other
  system resources." CPU and wakeup limits (`EXC_RESOURCE`) and thermal pressure also apply. After
  termination there's no relaunch for standard location updates.
- **The CPU monitor can kill a background app** (*added 2026-11-03*; `EXC_RESOURCE` `CPU` / `CPU_FATAL`).
  Apple publishes no limit. Logged ones: DTS quoting a killed background VoIP app, "exceeding limit of 60%
  cpu over 15 second" (forum 758387: treat the limits "as a hard limit that your app shouldn't be getting
  anywhere near"); a BGProcessingTask "exceeding limit of 80% cpu over 60 seconds … Process killed" (forum
  123975); background location and CarPlay navigation apps killed at "15% cpu over 60 seconds" in iOS
  15.2–15.3, fixed in 15.4 (forum 700124). The percentage is CPU time over wall time (100 % = one core).
  Termination code `0xd00d2bad` means "excessive use of key system resources". Stay well under about 30 % of
  one core; the Phase 0 build measures its background cost (`[bg-probe] … cpu=` lines).

**Staying alive doesn't keep the Wi-Fi association.** DTS lists, among the "circumstances where iOS will
leave a Wi-Fi network":

- "Device sleep, which typically happens shortly after screen lock"
- "After 30 minutes of not having a Wi-Fi app active"

`UIRequiresPersistentWiFi = YES` makes the app a "Wi-Fi app". Apple's key reference says that with it,
iOS "keeps it open while the app is running"; without it, "iOS closes the active Wi-Fi connection after 30
minutes". DTS is "least confident" about how Wi-Fi apps behave today. Consumer reports describe Wi-Fi
dropping about 30 s after lock unless the phone is charging (anecdotal, low).

*Added 2026-11-03:*

- Quinn (DTS, forum 662951): "It's not just the Wi-Fi chip that goes to sleep. Unless there's something that
  specifically prevents it — like music playback — the system aims to sleep the entire application
  processor." Asked whether an app can stop it: "No." **High** (statement).
- A developer relaying Wi-Fi traffic from a Network Extension saw the device disassociate in system sleep
  although packets flowed every second (same thread; single report, no location session). **Low–Medium**.
- DTS on `UIRequiresPersistentWiFi` (forum 765960, 2024): "The exact semantics … are fuzzy, and I suspect that
  they have drifted"; set it if the app benefits from staying on Wi-Fi (the app does).
- DTS (forum 848895, 2026) recommends `joinOnce = true` for a no-internet accessory, because with `false` iOS
  treats it like any saved network — and one iOS 26 report saw a nearly idle accessory link dropped for a
  saved internet network. `joinOnce = true` is unusable locked (torn down on device sleep), so the app keeps
  `false` and keeps the link busy (the REQ 114 pull loop does, even in hold).

Whether a running location app with live TCP traffic keeps the dash Wi-Fi while locked is **the main
device-test question** (open question 1). Still **Low**: charging and continuous traffic should help, audio
playback is the only exception Apple names.

**App Review 2.5.4** (guidelines updated 2026-10-16): "Multitasking apps may only use background services
for their intended purposes: VoIP, audio playback, location, task completion, local notifications, etc."

- Real-time turn-by-turn navigation is Apple's own example of a valid background location use.
- Reviewers reject apps whose background location isn't tied to a persistent-location feature, and may ask
  for a video.
- Turn background location on only for an active ride or navigation session, not for mirroring alone.
- Guideline 2.4.2 (battery and heat) also applies.

**`audio` mode for spoken prompts.** Starting playback from the background requires the mode.
`AVAudioSession.ErrorCode.cannotStartPlaying` "can also occur if the app is in the background and using a
category that doesn't allow background audio".

- Use `.playback` with mode `.voicePrompt`, which Apple names for turn-by-turn navigation.
- Add `.duckOthers`, which "implicitly sets `mixWithOthers`", plus `.interruptSpokenAudioAndMixWithOthers`.
- Activate the session just before speaking. Deactivate with `.notifyOthersOnDeactivation`. Apple: duck
  "on a temporary basis only".
- Voice prompts are legitimate audible content. A silent keep-alive loop draws the standard rejection, "we
  were unable to play any audible content when the app was running in the background".

### Practical guidance

```swift
lm.allowsBackgroundLocationUpdates = true
lm.pausesLocationUpdatesAutomatically = false
lm.activityType = .automotiveNavigation
lm.showsBackgroundLocationIndicator = true
lm.desiredAccuracy = kCLLocationAccuracyBestForNavigation
lm.startUpdatingLocation()                   // from the foreground, at ride start; stop at ride end

let s = AVAudioSession.sharedInstance()
try s.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
try s.setActive(true); synth.speak(utterance)      // on didFinish:
try s.setActive(false, options: .notifyOthersOnDeactivation)
```

### Sources

- https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates
- https://developer.apple.com/documentation/corelocation/cllocationmanager/pauseslocationupdatesautomatically
- https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background
- https://developer.apple.com/documentation/corelocation/clactivitytype/automotivenavigation
- https://developer.apple.com/documentation/corelocation/cllocationupdate/isstationary
- https://developer.apple.com/documentation/xcode/configuring-background-execution-modes
- https://developer.apple.com/documentation/bundleresources/information-property-list/uirequirespersistentwifi
- DTS, Wi-Fi lifecycle: https://developer.apple.com/forums/thread/734361
- Application-processor sleep: https://developer.apple.com/forums/thread/662951
- `UIRequiresPersistentWiFi` semantics: https://developer.apple.com/forums/thread/765960
- `joinOnce` for accessories: https://developer.apple.com/forums/thread/848895
- CPU limits: https://developer.apple.com/forums/thread/758387, https://developer.apple.com/forums/thread/123975,
  https://developer.apple.com/forums/thread/700124
- `EXC_RESOURCE`: https://developer.apple.com/documentation/xcode/exc_resource
- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotstartplaying
- https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voiceprompt
- https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/duckothers
- https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/interruptspokenaudioandmixwithothers
- Rejection pattern for `audio` without audible content: https://developer.apple.com/forums/thread/95216
- Background-location rejection pattern: https://developer.apple.com/forums/thread/771202

---

## f) Screen mirroring: ReplayKit Broadcast Upload Extension, and ScreenCaptureKit on iOS 27+

### Answer

**ReplayKit is deprecated in the iOS 27 SDK.** The docs metadata marks these deprecated as of 27.0:

- `RPBroadcastSampleHandler`: "No longer supported"
- `RPSystemBroadcastPickerView` and `preferredExtension`: "Use ScreenCaptureKit SCContentSharingPicker
  instead"
- `RPScreenRecorder`
- `RPVideoSampleOrientationKey`

The ScreenCaptureKit docs say: "ScreenCaptureKit replaces ReplayKit for screen streaming and mirroring. A
broadcast extension is no longer necessary."

An Apple engineer (thread 831465): "ScreenCaptureKit will be used for screen sharing starting in iOS 27.
You can use SCContentSharingPicker in place of the broadcast extension. Frames will flow through
SCStreamOutput to your host app."

iOS 27 adds `UIBackgroundModes` value `screen-capture`: "The app captures and streams screen content while in
the background". Apple's sample declares it "so the stream survives backgrounding for full-display
capture". *Added 2026-11-03:* the mode is checked explicitly (−3824 without it, even with silent audio
running), and App Store Connect's upload allowlist rejected the value until Aug 2026. On iOS, `SCStreamConfiguration.width`/`height` are available, but `minimumFrameInterval` and
`pixelFormat` are macOS-only.

Deprecated APIs still run, per secondary sources. Guideline 2.5.1 asks apps to phase out deprecated
technologies.

**For the legacy path (iOS 17–26):**

| Topic | Fact | Confidence |
| --- | --- | --- |
| Memory limit | **~50 MB.** Not in Apple docs. Twilio: "limited to 50 MB (as of iOS 12.2)". ReplayKit's own buffer queue counts against it and spikes (forum 651367 shows several full-resolution 4:2:0 surfaces). Budget about 25 MB for our own code. | Medium |
| Hardware H.264 in the extension | Works. This is standard practice (Twilio's extension prefers H.264 "to reduce memory"). The extension's lifetime is tied to the broadcast, not to the host app's background state. | Medium-high |
| Outbound TCP from the extension | Works. All broadcast SDKs do it. | High |
| `NWListener` on fixed ports in the extension | Not documented either way. Ports are device-wide, so the extension can't bind 10920–10922 while the host app holds them. | Low |
| Local Network permission | Shared with the container app. Extensions "assumed to be running in the background" are **silently denied** while the state is undetermined, so the host must get the permission first. Put the keys in the host `Info.plist`. | High |
| Starting it from the app | `RPSystemBroadcastPickerView`: set `preferredExtension` to the extension bundle ID and `showsMicrophoneButton = false`. The user taps, the system shows the sheet and a countdown. Programmatically "tapping" the internal button is undocumented and fragile. One report says `preferredExtension` was ignored on some devices. | High / Medium |
| Buffers | Video `CMSampleBuffer`s at native screen pixel size, in `420YpCbCr8BiPlanarFullRange` (forum 127985). Variable frame rate, **up to 30 fps**, only when the screen changes (Twilio). | Medium |
| Orientation | `RPVideoSampleOrientationKey` attachment, an `NSNumber` holding a `CGImagePropertyOrientation` raw value. The buffer stays portrait; in landscape the picture lies on its side in it. **Its quarter turns are the opposite of the EXIF meaning:** 6 (`.right`) needs a 90° counter-clockwise turn to be upright, 8 (`.left`) a 90° clockwise one (1–4 read the same either way). **Field report** (second field test: iPhone 14 Pro Max, iOS 27.0.1, CFMOTO 450MT): with the tag read as EXIF, the rider saw a full-screen YouTube video in landscape "al revés" on the dash (no photo or log; the direction and tag were not recorded), while portrait mirroring was upright in the photos. That fits the 180° error that inverted quarter turns give. WebDriverAgent PR #39 measured the same on iOS 26.6.1, and react-native-webrtc maps `.left` to a 90° clockwise rotation and `.right` to 270°. The app converts the tag with `MirrorFitMath.displayOrientation(replayKitValue:)` (not yet ridden). Rotate with `VTPixelRotationSession` and scale with `VTPixelTransferSession` (both iOS 16+). | High (device: PR #39; field report) |
| Threading | "ReplayKit invokes methods in your `RPBroadcastSampleHandler` subclass in a serial fashion". Return from `processSampleBuffer` quickly. | High |
| Screen lock | A secondary source says recording "stops automatically when the screen locks or there is an incoming call". Expect the broadcast to end or pause, so the user must restart it. | Low |
| Talking to the host app | App Group container (shared `UserDefaults(suiteName:)`), Darwin notifications (no payload), and an **AF_UNIX socket file in the App Group container**. Jitsi's sample does this: socket `rtc_SSFD`, plus Darwin notifications for start and stop. Watch the 104-byte `sun_path` limit. App Groups are allowed on free teams. | High (pattern) |

### Practical guidance

```swift
let tag = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                           attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 1
// Not an EXIF correction: 6 and 8 are swapped (see Orientation above).
let orientation = CGImagePropertyOrientation(rawValue: MirrorFitMath.displayOrientation(replayKitValue: tag)) ?? .up
// rotate (VTPixelRotationSession) + scale to ≤ 800×944 (VTPixelTransferSession) → VTCompressionSession
// → send Annex-B NAL units over the App-Group Unix socket to the host, which owns the dash link.
```

### Sources

- ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit
- Capturing screen content on iOS: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios
- Apple engineer: https://developer.apple.com/forums/thread/831465
- Background modes table: https://developer.apple.com/documentation/xcode/configuring-background-execution-modes
- https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler
- https://developer.apple.com/documentation/replaykit/rpsystembroadcastpickerview
- https://developer.apple.com/documentation/replaykit/rpvideosampleorientationkey
- Twilio ReplayKit README: https://github.com/twilio/video-quickstart-ios/blob/master/ReplayKitExample/README.md
- https://developer.apple.com/forums/thread/651367
- https://developer.apple.com/forums/thread/127985
- Jitsi sample: https://github.com/jitsi/jitsi-meet-sdk-samples/blob/master/ios/swift-screensharing/JitsiSDKScreenSharingTest/Broadcast%20Extension/SampleHandler.swift
  and SocketConnection.swift in the same folder
- Screen-lock behavior (search excerpt only): https://www.tencentcloud.com/document/product/1071/41878
- https://developer.apple.com/documentation/videotoolbox/vtpixelrotationsession
- ReplayKit quarter turns measured on a device (iPhone 15 Pro, iOS 26.6.1):
  https://github.com/droidrun/WebDriverAgent/pull/39
- Tag → `RTCVideoRotation` in react-native-webrtc (Jitsi's screen sharing):
  https://github.com/react-native-webrtc/react-native-webrtc/blob/master/ios/RCTWebRTC/ScreenCapturer.m

---

## g) Handlebar buttons over Bluetooth AVRCP

### Answer

**Track and play/pause keys arrive as `MPRemoteCommand`s, and only for the Now Playing app.** Apple: "Your
app must be the Now Playing app. An app doesn't receive remote control events until it begins playing
content."

WWDC19 501: "You become the Now Playing app by doing two things, one is to at least support one remote
control command and the other is to initiate playback … on iOS, that means activating your audio session
with a **non-mixable** category."

A voice-prompt session using `.duckOthers` or `.interruptSpokenAudioAndMixWithOthers` is mixable, so it
**never** makes us Now Playing. Consequences:

- Capturing buttons means a non-mixable `.playback` session that is actually playing, which **interrupts the
  rider's music**.
- When the rider starts music in another app, that app becomes Now Playing and receives the handlebar keys.
- `MPNowPlayingInfoCenter.playbackState` "only applies to macOS". On iOS, "playing" comes from actual audio
  plus `MPNowPlayingInfoPropertyPlaybackRate`.

**Now Playing text on the dash.** The dash shows our Now Playing title and artist, scrolling, in its own
media pill over the projected picture, in its own font. **Seen in the second field test** (CFMOTO 450MT,
photos): that font drew ◀ ▶ as empty boxes ("OpenCfMoto ▯ ▯ mov…"); ★ and · were not caught on camera,
and another photo shows "oup", the end of the artist. The metadata is printable ASCII
only (`HandlebarNowPlayingMetadata`, input-controls.md §9.1).

**Silent audio loop.** It works technically and the Android port uses an equivalent. It is an App Review
risk under 2.5.4: the standard rejection is "unable to play any audible content when the app was running in
the background". Present it as an opt-in "handlebar capture" mode that is tied to audible prompts, and
document it in the review notes. Otherwise expect rejection.

**▲/▼ on non-touch dashes.** These are AVRCP *absolute volume*, so there is no key event. iOS can only
observe system volume, through KVO on `AVAudioSession.outputVolume`. Caveats:

- It is reliable only while our session is active.
- It is reported stale after re-activation and while in the background on iOS 18+ (forums 813242 and
  799104).
- No event fires at 0 or at maximum.
- Every press really changes the rider's volume and shows the HUD.
- There is no public API to re-center the volume. The `MPVolumeView` slider hack is unsupported and risks
  guideline 2.5.9 ("Apps that alter or disable the functions of standard switches, such as the Volume
  Up/Down … will be rejected").

Treat it as experimental and off by default.

**HID remotes and keyboards are foreground-only.** `GCController.shouldMonitorBackgroundEvents`: "In iOS and
tvOS, the framework ignores this property." *(This corrects the claim in `input-controls.md` §8 that it
delivers controller input in the background on iOS.)*

### Sources

- https://developer.apple.com/documentation/mediaplayer/handling-external-player-events-notifications
- https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter
- WWDC19 501: https://developer.apple.com/videos/play/wwdc2019/501/
- Sample code *Becoming a now playable app*: https://developer.apple.com/documentation/mediaplayer/becoming-a-now-playable-app
- https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter/playbackstate
- https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume
- https://developer.apple.com/forums/thread/813242
- https://developer.apple.com/forums/thread/799104
- https://developer.apple.com/documentation/gamecontroller/gccontroller/shouldmonitorbackgroundevents
- App Review 2.5.4 and 2.5.9: https://developer.apple.com/app-store/review/guidelines/

---

## h) QR scanning

### Answer

**`DataScannerViewController`** (VisionKit, iOS 16+):

- `isSupported` requires "the A12 Bionic chip or later". It is `false` on visionOS.
- `isAvailable` means camera access is granted and not restricted, for example by Screen Time.
- It needs `NSCameraUsageDescription`.
- You get guidance, highlighting, tap-to-focus and pinch-to-zoom for free.

iOS 17 runs only on A12-or-later iPhones (XS/XR and newer), so with our iOS 17 iPhone target it is
effectively always supported. Still check the flags: for example, an iPhone app running on a Mac or on an
A10 iPad.

**`AVCaptureMetadataOutput`** (`.qr`) works on every device but needs our own UI (`rectOfInterest`,
overlay, permission flow).

**Recommendation:**

- Use DataScanner as the primary scanner and `AVCaptureMetadataOutput` as the fallback.
- Add *Import from photo*, using Vision barcode detection on a screenshot of the QR.
- Add manual SSID and password entry.

The iPhone Camera app would open the QR's `http://www.carbit.com.cn/...` URL in Safari. We can't claim that
domain as a universal link, so in-app scanning is required.

### Sources

- https://developer.apple.com/documentation/visionkit/datascannerviewcontroller
- https://developer.apple.com/documentation/visionkit/datascannerviewcontroller/issupported
- https://developer.apple.com/documentation/visionkit/scanning-data-with-the-camera
- https://developer.apple.com/documentation/avfoundation/avcapturemetadataoutput
- iOS 17 device list (secondary): https://9to5mac.com/2023/09/18/ios-17-compatible-iphone/

---

## i) Distribution, licensing and free provisioning

### Answer

**(A)GPL on the App Store.** History:

- 2010: Apple removed a GNU Go port after an FSF letter. The FSF's view is that the App Store "Usage Rules"
  add restrictions on use and distribution that the GPL forbids.
- January 2011: VLC was pulled after a VLC developer complained.
- July 2013: VLC returned **bi-licensed under MPLv2 and GPLv2+**, with "the MPLv2 applicable for
  distribution on the App Store". The repo's `COPYING` still says so.

The FSF analysis has not been withdrawn. Current practice:

- Copyright holders do publish (A)GPL apps: Signal-iOS is AGPL-3.0 and Mastodon for iOS is GPL-3.0. A
  licensor isn't bound by its own license.
- The residual risk sits with *third-party* copyright holders who never agreed.
- Apple lets you supply a custom EULA, but it must include Apple's minimum terms, so it doesn't settle the
  question.
- The usual remedy is a GPLv3 §7 *additional permission* for App Store distribution. Signal did this for
  libsignal (signal.org, search excerpt only).

**This port is a derivative of `zanderp/open-cfmoto`** (AGPL, copyright Alexandru and contributors). App
Store or TestFlight distribution by anyone else is only clean with upstream's written additional
permission. Get a lawyer's view.

Also:

- Keep a "Source code" link in the app, which serves the spirit of AGPL §13.
- Guideline 5.2.1 (trademarks) puts the name "OpenCfMoto" at risk for store builds. Prefer a neutral name
  with "compatible with CFMOTO" wording.

**TestFlight** (needs the paid program):

- up to 100 internal testers and **up to 10,000 external testers**, including by public link
- the first build sent to external testers goes through App Review
- a build can be tested **for up to 90 days**
- up to 100 builds can be shared
- *added 2026-11-03:* builds for **internal** testers get no App Review, but App Store Connect's upload
  validation still runs on them (in Aug 2026 it rejected an unknown `UIBackgroundModes` value until Apple
  fixed its allowlist)

**EU (and Japan) alternative distribution.** EU users on iOS 17.4+ can install notarized apps from
alternative marketplaces or via Web Distribution. Requirements and terms:

- The paid program and **Notarization** (a security- and privacy-focused subset of the App Review
  Guidelines).
- From 2026-10-01 a single set of EU terms applies: a 5% **Core Technology Commission** on digital sales,
  replacing the old Core Technology Fee. A free app with no sales pays nothing.
- AltStore PAL is an open-source EU marketplace. It also launched in Japan in December 2025.

These channels avoid the App Store's Usage Rules, but builds are still Apple-signed and notarized.

**AltStore (classic) and SideStore.** Both sign with the *user's own* free Apple ID, so all free-team
limits apply:

- 3 active sideloaded apps.
- App IDs: each app extension needs its own App ID, within the 10-ID limit.
- Re-signing every 7 days: AltServer on a computer, or SideStore on the device using a VPN pairing file.
  This breaks with iOS updates. iOS 26.4 broke SideStore refresh until a July 2026 nightly fix.

**Free Personal Team limits** (Apple):

- up to 10 App IDs, which expire after 7 days
- up to 3 devices
- up to 3 apps per device
- provisioning profiles expire after 7 days

Capability availability on free accounts:

| Available free | **Not** available free (ADP/ADEP only) |
| --- | --- |
| App groups, Background modes, Data protection, HealthKit, HomeKit, Inter-App Audio, Keychain sharing, Maps (but **no routing directions**), Wireless Accessory Configuration | **Hotspot**, **Access WiFi information**, **Network extensions**, Personal VPN, Multipath, Push notifications, Associated domains, iCloud, Sign in with Apple, App Attest, NFC, Wallet, WeatherKit, Time Sensitive Notifications, Sustained Execution, … |

The multicast networking entitlement is a request-only managed capability, so it isn't available free. It
also isn't needed (see c).

**Consequence for free builds:**

- There's no programmatic join. The rider joins the dash Wi-Fi in Settings, and we show the password with a
  copy button (a local-only copy that expires after 2 minutes). Apps can only open their own Settings page, not
  the Wi-Fi page.
- There's no SSID read.
- Detect the join through the `NWPath` gateway and a successful probe.

### Sources

- Capability table and free-account notes: https://developer.apple.com/help/account/reference/supported-capabilities-ios
- Free team limits: https://developer.apple.com/support/compare-memberships/
- TestFlight: https://developer.apple.com/testflight/
  and https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- EU: https://developer.apple.com/support/dma-and-apps-in-the-eu/
  and https://developer.apple.com/support/alternative-app-marketplace-in-the-eu/
- Custom EULA: https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement
- App Review Guidelines (5.2.1, 2.5.1, 2.5.2): https://developer.apple.com/app-store/review/guidelines/
- FSF and GNU Go (2010): https://lwn.net/Articles/391423 and https://www.theregister.com/2010/05/27/gnu_go_fsf_apple_itunes/
- VLC removal: https://thenextweb.com/news/apple-officially-pulls-vlc-from-the-app-store
- VLC return: https://thenextweb.com/news/vlc-for-ios-will-return-to-the-app-store-on-july-19-full-re-write-open-source-licensed-under-mplv2-and-gplv2
  and https://raw.githubusercontent.com/videolan/vlc-ios/master/COPYING
- Pidgin's analysis: https://developer.pidgin.im/wiki/WhyNoiOSVersion
- Signal-iOS license: https://github.com/signalapp/Signal-iOS/blob/main/LICENSE
- AltStore: https://faq.altstore.io/altstore-world/app-ids
  and https://www.macrumors.com/2025/12/18/altstore-japan-launch/
- SideStore iOS 26.4 breakage: https://github.com/SideStore/SideStore/issues/1237

---

## j) Wi-Fi IPv4 address, netmask and default gateway

### Answer

**Address and netmask.** `getifaddrs` is public and gives `ifa_addr` and `ifa_netmask` for each interface.
**Don't hard-code `en0`.** TN3179: "BSD interface names, like `en0`, aren't considered API … your app will
fail for a small fraction of those users." Identify the Wi-Fi interface by its *functional type*:

- `NWPathMonitor(requiredInterfaceType: .wifi)`, then take the `NWInterface` (type `.wifi`) and use its
  `name` to filter `getifaddrs`, or
- the `SIOCGIFFUNCTIONALTYPE` ioctl. DTS shows a C helper, because Swift doesn't import the constant.

**Our own IP for the probe.** Use the probe connection's `currentPath?.localEndpoint`. That is DTS's
recommended way to learn the local address of an outgoing connection.

**Default gateway.** `NWPath.gateways` is public (iOS 13+): "A list of gateways configured on the
interfaces available to a path". On a Wi-Fi-only path monitor we expect the dash's 192.168.0.1 or
192.168.49.1. That still needs a device check. Routing sockets and `sysctl` (`PF_ROUTE`,
`NET_RT_FLAGS`/`NET_RT_DUMP`) are **unsupported on iOS**. DTS: "Other Apple platforms don't support routing
sockets … the declarations required to use the socket, most obviously `rt_msghdr`, are only present in the
macOS SDK. And no, copying declarations from one SDK to another is not supported."

**Fallback ladder:**

1. `NWPath.gateways`
2. `x.y.z.1` of the Wi-Fi subnet from `getifaddrs`
3. the known addresses, 192.168.0.1 and 192.168.49.1
4. a Bonjour `_EasyConn._tcp` resolve, which needs Local Network permission

### Sources

- https://developer.apple.com/documentation/network/nwpath/gateways
- TN3179, *Identify the Wi-Fi interface correctly*: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- DTS, *Network Interface APIs*: https://developer.apple.com/forums/thread/734338
- DTS, *Don't Try to Get the Device's IP Address*: https://developer.apple.com/forums/thread/734295

---

## k) Keeping the screen on, and thermal or power adaptation

### Answer

**Idle timer.** `UIApplication.shared.isIdleTimerDisabled = true`. Apple: "The only apps that should
disable the idle timer are mapping apps, games, or programs where the app needs to continue displaying
content when user interaction is minimal." Set it only during an active ride and reset it afterwards. It
works only while the app is frontmost and does nothing if the rider presses the side button.

**Brightness.** `UIScreen.brightness` can be lowered. "Brightness changes remain in effect until the
person locks their device … the system restores the brightness setting" on unlock. That suits a dark
"pocket mode".

**Proximity.** `UIDevice.isProximityMonitoringEnabled` (enable it, then check that the value stuck). Community
reports say the screen blanks while the sensor is covered. Whether the app stays active, and whether it
works in landscape, are unverified (low).

**Thermal state.** `ProcessInfo.processInfo.thermalState` has four levels: `.nominal`, `.fair`, `.serious`
and `.critical`. Apple's guidance:

- `.fair`: defer background work.
- `.serious`: "Reduce CPU and GPU usage … Reduce the target framerate … Reduce the level of detail".
- `.critical`: reduce "to the minimum level required for user interaction".

Observe it with `thermalStateDidChangeNotification`. You "must access the `thermalState` prior to
registering for the notification".

**Low Power Mode.** `isLowPowerModeEnabled` together with `NSProcessInfoPowerStateDidChange`.

**Encoder changes on a live session.** VT properties such as `AverageBitRate`, `DataRateLimits` and
`ExpectedFrameRate` can be set on a live session. The dash pulls frames, so slower pacing is just "send the
latest frame".

**Optional.** `com.apple.developer.sustained-execution` (paid only) locks the app to a sustainable
performance level, which avoids changes in thermal headroom over time. It is not needed.

### Sources

- https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled
- https://developer.apple.com/documentation/uikit/uiscreen/brightness
- https://developer.apple.com/documentation/uikit/uidevice/isproximitymonitoringenabled
- https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum
  and the `/serious` and `/critical` case pages
- https://developer.apple.com/documentation/foundation/processinfo/thermalstatedidchangenotification
- https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.sustained-execution

---

## Things only a real device can settle

1. **Wi-Fi while locked.** Does iOS keep the dash association while the phone is locked, with a
   `location`-background process streaming TCP? Test with and without charging, and with and without
   `UIRequiresPersistentWiFi`. Test on iOS 17, 18, 26 and 27.
2. **VideoToolbox in the background.** Exactly how does a `VTCompressionSession` fail after backgrounding or
   locking (−12903 or −12915)? Does creating a new one in the background fail? Does
   `EnableHardwareAcceleratedVideoEncoder = false` (iOS 17.4+) yield a usable software encoder that also
   runs in the background? *2026-11-03:* the Phase 0 diagnostics build answers this from one locked test
   (encoder list, a session pre-warmed in the foreground and probed, fresh and `EncoderID` sessions in the
   background, each with its OSStatus, `hw=` and probe result), and question 1 with `[lock]` lines every 30 s
   (link, Wi-Fi, pulls, GPS and heading age, battery) and a marker that tells on the next launch whether iOS
   ended the app in the background.
3. **Default route on the dash network.** With the dash joined (its DHCP hands out a router and DNS), does
   the default route stay on cellular, so MapKit and URLSession still work? Does iOS prompt to "stay
   connected without internet", or hop to saved networks?
4. **Cellular-bound DNS and connect.** Do `requiredInterfaceType = .cellular` DNS lookups and connections
   succeed reliably while on the dash Wi-Fi? Test with Low Data Mode, roaming and eSIM.
5. **`NWPath.gateways`.** Is it populated for the dash Wi-Fi path, on both the access-point and Wi-Fi
   Direct dashes?
6. **CFDL26 Wi-Fi Direct group owner.** Does it accept an iPhone as a legacy client (band and channel,
   protected management frames)? Is the passphrase stable across power cycles? Does the dash care about the
   iPhone's private (randomized) Wi-Fi MAC address?
7. **Local Network alert.** When does it appear in our flow? Is the first probe denied immediately and then
   retried? What does the extension see if the host was denied?
8. **Broadcast extension.** Real fps and memory headroom with an 800×944 encode inside about 50 MB. Lock
   behavior: `broadcastPaused` or `broadcastFinished`? Is the CPU cost acceptable?
9. **iOS 27 ScreenCaptureKit.** Does `screen-capture` mode keep capture *and* VideoToolbox encode alive
   when the app is backgrounded or the device is locked?
10. **Handlebar buttons.** Which AVRCP commands does each dash send to iOS (track keys, play/pause,
    seek begin/end, absolute volume)? Do they arrive only while we are Now Playing?
11. **Pocket mode.** With proximity monitoring enabled, does the app stay `.active` with the screen off?
    Does that work in landscape? What are the battery drain and the thermal state after an hour?
12. **Port conflicts.** With the official vendor app installed, does it hold 10920–10922 in the background?

---

## Design recommendations

1. **Make foreground "Ride Mode" the primary operating mode.** Keep the app frontmost during a ride:
   - `isIdleTimerDisabled = true` (Apple explicitly allows it for mapping apps)
   - a black, touch-swallowing pocket overlay
   - lowered `UIScreen.brightness`, restored by the system at lock
   - optional proximity blanking, after the device test

   This is the only configuration in which Metal or Core Animation, the hardware H.264 encoder and the Wi-Fi
   association are all reliably available. Tell the rider that locking the phone degrades the dash.
2. **Treat background or locked operation as best-effort, using CPU-only paths.** On
   `didEnterBackground`:
   - Stop all GPU, Core Image, MapKit and VideoToolbox work.
   - Switch the dash renderer to Core Graphics at a reduced rate (5–10 fps).
   - Switch to a background encoder through the ladder of decision 4.
   - Keep sockets and listeners up.

   On `didBecomeActive`, recreate the VT session and force an IDR frame. *2026-11-03:* the background path is
   CPU only by construction (Core Graphics, vImage; no `VTPixelTransferSession`, Core Image or Metal), and
   the Phase 0 build measures its cost in hold with a dry run (render, convert to I420, 10 ms of load, at
   8 fps for 10 minutes) before any encoder is bundled.
3. **Render the dash with Core Graphics only.** Draw into IOSurface-backed 32BGRA `CVPixelBuffer`s from a
   `CVPixelBufferPool`, and convert to NV12/I420 with vImage when the software encoder needs it. Build our
   own tile or vector map renderer, fed by tiles fetched over cellular. Use MapKit only in the phone UI:
   `MKMapSnapshotter` doesn't work in the background, and routing directions need the paid program.
4. **Put an encoder protocol in front of the encoders** — *implemented (2026-11-03)* as `DashVideoEncoder`
   (`OpenCfMotoApple/DashVideoEncoder.swift`) with a background ladder:
   - foreground: **VideoToolbox hardware**, unchanged: Baseline, `RealTime`, no frame reordering, IDR every
     second, on-demand IDR, live bitrate and frame rate. Don't use `EnableLowLatencyRateControl` unless the
     dash is shown to decode its output;
   - background, the first rung whose probe IDR passes the stream check (`H264StreamCheck`) wins: (1) a
     **VideoToolbox software** session (`EnableHardwareAcceleratedVideoEncoder = false`, pre-warmed at
     `.inactive`, or fresh, or by `EncoderID`); (2) a **bundled CPU encoder** (Phase 1, owner's decision:
     minih264, OpenH264 (BSD-2) or a hand-written one; absent in the Phase 0 build); (3) the pre-encoded
     **hold picture**. A failing encoder is demoted to the next rung.

   Phase 0 is the spike: if the VideoToolbox software session works in the background on the owner's iPhone,
   nothing is bundled.
5. **Keep the process alive during rides with classic `CLLocationManager`:**
   - `allowsBackgroundLocationUpdates = true`
   - `pausesLocationUpdatesAutomatically = false`
   - `.automotiveNavigation`
   - `showsBackgroundLocationIndicator = true`
   - start in the foreground at ride start and stop at ride end
   - request **When-In-Use only**, and drop the Always string unless a relaunch feature needs it

   Enable background location only while a ride or navigation is active (App Review 2.5.4).
6. **Join the dash with persistent configurations (`joinOnce = false`).** `joinOnce = true` dies on device
   sleep or after 15 s in the background.
   - Before calling `apply`, check whether we are already on the dash network (gateway or SSID).
   - Treat `alreadyAssociated` as success.
   - Use a retry policy for `.internal`.
   - Offer a *Forget bike Wi-Fi* action.
   - Monitor with `NWPathMonitor` for iOS hopping to another saved network, and re-apply on the next
     foreground or post a notification.
   - Add `UIRequiresPersistentWiFi = YES` to `Info.plist`, and check it doesn't trigger unwanted Wi-Fi UI.
7. **Split traffic explicitly.** Dash traffic uses `requiredInterfaceType = .wifi` (probe and three
   listeners). While the dash link is up, internet traffic uses `requiredInterfaceType = .cellular`
   through a small `InternetTransport` (HTTP/1.1 over `NWConnection` with `NWProtocolTLS`).
   - Spike the loopback CONNECT/SOCKS proxy behind `URLSessionConfiguration.proxyConfigurations` (iOS 17+)
     to reuse URLSession-based code.
   - Surface `.cellularDenied` to the user.
   - Keep the Android app's polite User-Agent and request spacing.
8. **Order the session the way TN3179 implies.** Start `NWListener`s on 10920–10922 first. They need no
   permission, no Bonjour advertising, and should use `allowLocalEndpointReuse`. Then send the outbound
   probe to `gateway:10930`, which needs Local Network permission and must run in the foreground the first
   time. Handle `EADDRINUSE` (another app holding the ports) with a clear message.
9. **Make Local Network permission an onboarding step.** Trigger the alert in the foreground (the TN3179
   UDP-connect technique, or the first probe), explain why, detect `.localNetworkDenied`, and link to
   Settings. Keep `NSLocalNetworkUsageDescription` and `NSBonjourServices [_EasyConn._tcp]` in the **app**
   `Info.plist`, and remove them from the Mirror extension's `Info.plist` per TN3179. No multicast
   entitlement is needed.
10. **Use one addressing helper with the j) ladder:** `NWPath.gateways`, then `x.y.z.1` of the Wi-Fi
    subnet, then 192.168.0.1 and 192.168.49.1, then Bonjour. The phone IP comes from the probe's
    `localEndpoint`. Find the Wi-Fi interface by functional type, never `en0`, and never use routing
    `sysctl`.
11. **Speak voice prompts with a transient mixable session:** `.playback` + `.voicePrompt` +
    `[.duckOthers, .interruptSpokenAudioAndMixWithOthers]`, activated per prompt and deactivated with
    `.notifyOthersOnDeactivation`. Keep the `audio` background mode for these audible prompts only. Never
    ship a hidden silent loop.
12. **Map handlebar inputs honestly:**
    - Dash touch, through the PXC protocol, is primary.
    - AVRCP track and play/pause capture is an explicit opt-in "Capture handlebar buttons" mode. It makes us
      the Now Playing app with a non-mixable session and must say clearly that it pauses other music.
    - The ▲/▼ absolute-volume path is experimental and off by default, with no `MPVolumeView` re-pin hack in
      store builds.
    - HID remotes work only in the foreground. Fix the `input-controls.md` §8 claim about background
      `GCController` events.
13. **Scan QR codes with `DataScannerViewController`** (`.barcode(symbologies: [.qr])`) when `isSupported &&
    isAvailable`. Fall back to `AVCaptureMetadataOutput`, plus *Import from photo* (Vision) and manual
    entry.
14. **Mirroring:**
    - On iOS 27+, implement mirroring in the host app with ScreenCaptureKit (`SCContentSharingPicker`, the
      `screen-capture` background mode, `SCStreamConfiguration.width`/`height` = dash size). There is no
      extension and no 50 MB limit, and the host owns the dash link.
    - Keep the ReplayKit Broadcast Upload Extension only as an optional legacy path for iOS 17–26. It
      encodes in the extension, keeps its own code under about 25 MB, sends NAL units to the host over an
      App-Group Unix socket, signals start and stop with Darwin notifications, and assumes the broadcast
      ends at screen lock.
15. **Adapt to thermal and power state** by observing `thermalState` and Low Power Mode:

    | State | Frame rate | Bitrate | Other |
    | --- | --- | --- | --- |
    | `.nominal` | 30 fps | full | — |
    | `.fair` | 20 fps | full | — |
    | `.serious` | 10–15 fps | −40% | simpler map style |
    | `.critical` | 5 fps | low | show a banner |

    Low Power Mode caps the frame rate at 15 fps. Recommend charging during rides; it also may help the Wi-Fi
    association while locked (unverified).
16. **Ship two build flavors from one codebase:**
    - (a) *Full* (paid team): Hotspot and Access-WiFi-Info entitlements.
    - (b) *Free / sideload*: an xcconfig switch selects an entitlements file without those two and sets a
      Swift flag, such as `OCM_NO_HOTSPOT`.

    The free flavor uses a manual-join flow (the app shows the password with a copy button, then the rider
    joins in Settings) with path and gateway detection. Document the 7-day re-sign, 3 apps / 3 devices, the extension's extra App ID, and
    the lack of MapKit routing.
17. **Settle licensing before any store or TestFlight build.**
    - Ask the upstream `open-cfmoto` copyright holders for a GPLv3 §7 App Store / TestFlight additional
      permission, and adopt a DCO or CLA that grants the same for new contributions.
    - Until then, distribute source, self-build and sideload, and (with ADP) consider EU or Japan
      alternative marketplaces.
    - Use a trademark-neutral store name, and keep an in-app "Source code" link (AGPL §13).
18. **Build diagnostics in from day one,** mirroring the Android log style. Log:
    - app-state transitions
    - `NWPath` changes (interfaces, gateways, unsatisfied reasons)
    - NEHotspot errors
    - VT `OSStatus` codes
    - thermal and power changes
    - remote-command events with timestamps

    This lets one ride resolve the open questions above.
