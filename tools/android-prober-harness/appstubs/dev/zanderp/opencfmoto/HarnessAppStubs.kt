// HARNESS STUBS (not upstream code). Thin stand-ins for upstream app classes whose real bodies are
// Android-only (Wi-Fi join, OpenGL compositor, map UI, TTS, foreground services, HTTP). Only the
// members the copied upstream files call exist; each documents what the real one does on the path
// the harness exercises. Upstream sources: zanderp/open-cfmoto app/src/main/java/dev/zanderp/opencfmoto/ (copied by copy_upstream.sh).
package dev.zanderp.opencfmoto

import android.content.Context
import android.view.Surface
import android.view.View

/**
 * BikeWifi.kt (real: WifiNetworkSpecifier join + NetworkCallback + VPN probes). The harness runs
 * EasyConnProber with network = null and gateway/bind overrides (the Wi-Fi Direct call shape in
 * BikeLink.kt:103), so `currentNetwork` is null and there is no VPN. Real behaviour in that state:
 *  - rebindProcessToBike: `val n = currentNetwork ?: return false`            (BikeWifi.kt:369)
 *  - isVpnActive: no TRANSPORT_VPN network → false                           (BikeWifi.kt:387)
 *  - vpnNetworksSummary: "" (no VPN network)                                 (BikeWifi.kt:401)
 *  - isVpnBindBlocked: `if (error == null || !isVpnActive(context)) return false` (BikeWifi.kt:424)
 *  - testBikeSocketBind: `val n = currentNetwork ?: return null`             (BikeWifi.kt:443)
 */
object BikeWifi {
    fun rebindProcessToBike(context: Context): Boolean = false
    fun isVpnActive(context: Context): Boolean = false
    fun vpnNetworksSummary(context: Context): String = ""
    fun isVpnBindBlocked(context: Context, error: Throwable?): Boolean = false
    fun testBikeSocketBind(context: Context): Exception? = null
}

/** AaCompositor.kt (real: EGL/GLES letterbox compositor). Only used in AA / mirror mode — never here. */
class AaCompositor(private val log: (String) -> Unit) {
    @Volatile var inputSurface: Surface? = null
    fun start(bufferW: Int = 0, bufferH: Int = 0) { inputSurface = Surface() }
    fun updateCaptureSize(w: Int, h: Int) {}
    fun setOutput(encoderSurface: Surface, cw: Int, ch: Int, sw: Int, sh: Int, fit: ScreenFit) {}
    fun setPreview(surface: Surface, w: Int, h: Int) {}
    fun updatePreviewSize(w: Int, h: Int) {}
    fun clearPreview() {}
    fun mapCanvasToSource(cx: Int, cy: Int): Pair<Int, Int>? = null
    fun setSourceCrop(cu: Float, cv: Float) {}
    fun refreshMargins() {}
    fun setFrameCap(fps: Int) {}
    fun release() {}
}

/** GpxDashUi.kt (real: the projected map UI). Only reached when GpxSession.active — never here. */
class GpxDashUi(
    context: Context,
    root: View,
    log: (String) -> Unit,
    isAlive: () -> Boolean,
    projected: Boolean = false,
) {
    fun bind(): Boolean = false
    fun release() {}
}

/** GpxVoice.kt (real: TextToSpeech). VideoPipeline only ever calls shutdown() on a null field. */
class GpxVoice(context: Context) {
    fun shutdown() {}
}

/** ProjectionService.kt (real: MediaProjection foreground service); keep-screen-on is a no-op here. */
class ProjectionService {
    companion object {
        fun setKeepScreenOn(ctx: Context, on: Boolean) {}
    }
}

/** AppHttp.kt (real: cellular-pinned HTTP). GPX presentation only. */
object AppHttp {
    fun ensureCellularUplink() {}
}

/** AndroidAutoService.kt (real: AA receiver + watchdog service). Screen wake is a no-op here; the
 *  watchdog itself is re-implemented in the harness runner (harness/Watchdog.kt). */
class AndroidAutoService {
    companion object {
        fun setGpxScreenWake(ctx: Context, on: Boolean) {}
    }
}

/** MediaButtonBridge.kt (real: AVRCP / media-session buttons). No instance in the harness. */
class MediaButtonBridge {
    fun yieldForAaAudio(@Suppress("UNUSED_PARAMETER") holdMs: Long) {}
    companion object {
        @Volatile var instance: MediaButtonBridge? = null
    }
}
