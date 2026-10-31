// HARNESS (not upstream code). Records what EasyConnProber.emit() hands to AaVideoBridge.touchSink
// (after the upstream ghost filter / UP stitching), one JSON line per event.
package harness

import java.io.File
import java.io.PrintWriter

class TouchRecorder(file: File) {
    private val out = PrintWriter(file.bufferedWriter(), true)
    private val t0 = System.nanoTime()

    @Synchronized
    fun record(action: Int, pointerId: Int, x: Int, y: Int) {
        val name = when (action) { 0 -> "DOWN"; 1 -> "UP"; 2 -> "MOVE"; else -> "?$action" }
        val ms = (System.nanoTime() - t0) / 1_000_000
        out.println("{\"t_ms\":$ms,\"wall_ms\":${System.currentTimeMillis()},\"action\":\"$name\",\"id\":$pointerId,\"x\":$x,\"y\":$y}")
    }

    @Synchronized fun close() = out.close()
}
