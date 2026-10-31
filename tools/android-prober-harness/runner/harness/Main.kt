// HARNESS (not upstream code). Runs the ORIGINAL dev.zanderp.opencfmoto.EasyConnProber against a
// PXC dash reachable on --gateway, the same way the app does on the Wi-Fi Direct path
// (BikeLink.kt:103: start(network, gatewayOverride, bindIpOverride) with network == null).
package harness

import android.content.Context
import dev.zanderp.opencfmoto.AaVideoBridge
import dev.zanderp.opencfmoto.BikeMemory
import dev.zanderp.opencfmoto.BikeProfileHolder
import dev.zanderp.opencfmoto.BikeProfiles
import dev.zanderp.opencfmoto.ClockLab
import dev.zanderp.opencfmoto.ClockLabPreset
import dev.zanderp.opencfmoto.ConnectionState
import dev.zanderp.opencfmoto.EasyConnProber
import dev.zanderp.opencfmoto.LogBus
import dev.zanderp.opencfmoto.Phase
import dev.zanderp.opencfmoto.ProfileOverride
import dev.zanderp.opencfmoto.QrData
import java.io.File
import java.net.Inet4Address
import java.net.InetAddress
import kotlin.system.exitProcess

private const val USAGE = """usage: harness [--seconds N] [--gateway IP] [--bind IP] [--content-fps F] [--clips DIR]
               [--clips-cache DIR] [--touch-out FILE] [--no-watchdog] [--qr RAW] [--profile ID]
               [--clock-preset LATEST|V2012|ZONTES|PHONE_SYNC|BT_LISTEN] [--include-secrets]
               [--build-brand S] [--build-model S] [--build-sdk N]"""

fun main(args: Array<String>) {
    val o = HashMap<String, String>()
    val flags = HashSet<String>()
    var i = 0
    while (i < args.size) {
        val a = args[i]
        when (a) {
            "--no-watchdog", "--include-secrets" -> flags += a
            "-h", "--help" -> { println(USAGE); return }
            else -> {
                if (!a.startsWith("--") || i + 1 >= args.size) { System.err.println(USAGE); exitProcess(2) }
                o[a] = args[++i]
            }
        }
        i++
    }
    // Stub knobs are system properties (read by the Java stubs), set before any stub class loads.
    o["--content-fps"]?.let { System.setProperty("harness.content.fps", it) }
    o["--clips"]?.let { System.setProperty("harness.clips.dir", it) }
    o["--clips-cache"]?.let { System.setProperty("harness.clips.cache", it) }
    o["--build-brand"]?.let { System.setProperty("harness.build.brand", it) }
    o["--build-model"]?.let { System.setProperty("harness.build.model", it) }
    o["--build-sdk"]?.let { System.setProperty("harness.build.sdk", it) }

    val seconds = (o["--seconds"] ?: "20").toDouble()
    val gateway = InetAddress.getByName(o["--gateway"] ?: "127.0.0.1") as Inet4Address
    val bindIp = InetAddress.getByName(o["--bind"] ?: "127.0.0.1") as Inet4Address

    val ctx = Context()
    LogBus.includeSecrets = "--include-secrets" in flags          // upstream default: false (redacted)
    ClockLab.applyPreset(ClockLabPreset.valueOf(o["--clock-preset"] ?: "LATEST")) // upstream default
    BikeProfileHolder.profileOverride = ProfileOverride.byId(o["--profile"] ?: "auto")
    o["--qr"]?.let { raw ->
        // Same early pick as MainActivity.applyProfile(): QR → BikeProfiles.selectByQr (garage save first).
        val qr = QrData.parse(raw) ?: run { System.err.println("bad --qr"); exitProcess(2) }
        BikeMemory.save(ctx, raw, qr)
        BikeProfileHolder.active = BikeProfiles.selectByQr(qr, ctx)
        LogBus.log("[harness] QR early profile: ${BikeProfileHolder.active.name}")
    }

    val touches = o["--touch-out"]?.let { TouchRecorder(File(it)) }
    // What the prober forwards after its ghost filter / UP stitching (the AA input sink slot).
    AaVideoBridge.touchSink = { action, pointerId, x, y -> touches?.record(action, pointerId, x, y) }

    val prober = EasyConnProber(ctx, LogBus::log)        // MainActivity.kt:513
    LogBus.log("[harness] EasyConnProber gateway=${gateway.hostAddress} bind=${bindIp.hostAddress} run=${seconds}s " +
        "contentFps=${System.getProperty("harness.content.fps", "20")} watchdog=${"--no-watchdog" !in flags}")
    ConnectionState.set(Phase.PXC_CONNECTING)            // BikeLink.maybeStartProbe()
    val watchdog = if ("--no-watchdog" in flags) null else Watchdog(prober).also { it.start() }
    prober.start(null, gatewayOverride = gateway, bindIpOverride = bindIp)

    val deadline = System.nanoTime() + (seconds * 1e9).toLong()
    while (System.nanoTime() < deadline) {
        try { Thread.sleep(100) } catch (_: InterruptedException) { break }
    }
    LogBus.log("[harness] run time over — stopping prober (isStreaming=${prober.isStreaming} " +
        "msSinceLastFrame=${prober.msSinceLastFrame()} phase=${ConnectionState.phase})")
    watchdog?.stop()
    prober.stop()
    touches?.close()
    Thread.sleep(300)
    exitProcess(0)
}
