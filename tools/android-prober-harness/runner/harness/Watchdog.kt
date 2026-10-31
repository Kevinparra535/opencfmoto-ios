// HARNESS (not upstream code). Re-implementation of AndroidAutoService.tickWatchdog()
// (AndroidAutoService.kt:111-155 + companion constants :695-698), which is what drives
// EasyConnProber.forceReconnect()/rearmFromError() in the app. Same tick, thresholds, cooldowns,
// predicates and log line; AppSettings.autoRecovery defaults to true (AppSettings.kt:45).
package harness

import dev.zanderp.opencfmoto.ConnectionState
import dev.zanderp.opencfmoto.EasyConnProber
import dev.zanderp.opencfmoto.LogBus
import dev.zanderp.opencfmoto.Phase
import kotlin.concurrent.thread

class Watchdog(private val prober: EasyConnProber) {
    private companion object {
        const val WATCHDOG_TICK_MS = 5_000L
        const val STALL_MS = 8_000L
        const val ACTION_COOLDOWN_MS = 20_000L
        const val ERROR_COOLDOWN_MS = 20_000L
    }

    @Volatile private var running = false
    private var lastRecoveryAt = 0L
    private var t: Thread? = null

    fun start() {
        running = true
        t = thread(name = "harness-watchdog", isDaemon = true) {
            while (running) {
                try { Thread.sleep(WATCHDOG_TICK_MS) } catch (_: InterruptedException) { break }
                if (!running) break
                try { tick() } catch (_: Exception) {}
            }
        }
    }

    fun stop() { running = false; t?.interrupt() }

    private fun tick() {
        if (!prober.isRunning) return
        val now = System.currentTimeMillis()
        when {
            ConnectionState.phase == Phase.STREAMING &&
                prober.msSinceLastFrame() > STALL_MS &&
                now - lastRecoveryAt > ACTION_COOLDOWN_MS -> {
                LogBus.log("[watchdog] streaming stalled (${prober.msSinceLastFrame()}ms, no frames) — recovering")
                lastRecoveryAt = now
                prober.forceReconnect()
            }
            ConnectionState.phase == Phase.ERROR &&
                now - lastRecoveryAt > ERROR_COOLDOWN_MS -> {
                lastRecoveryAt = now
                prober.rearmFromError()
            }
        }
    }
}
