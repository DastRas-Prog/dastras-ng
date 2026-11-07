package com.dastras.ng

import android.content.Context
import java.io.File

/** VPN state shared between the app process and the separate :vpn service process (via a tiny file). */
object VpnState {
    class S(val state: String, val down: Long, val up: Long, val totDown: Long, val totUp: Long)

    private fun file(ctx: Context) = File(ctx.filesDir, "vpn_state.txt")

    fun write(ctx: Context, state: String, down: Long = 0, up: Long = 0, totDown: Long = 0, totUp: Long = 0) {
        try {
            val tmp = File(ctx.filesDir, "vpn_state.tmp")
            tmp.writeText(
                state.replace('|', '/') + "|" + System.currentTimeMillis() + "|" + down + "|" + up + "|" + totDown + "|" + totUp
            )
            tmp.renameTo(file(ctx))
        } catch (_: Exception) {
        }
    }

    fun read(ctx: Context): S {
        try {
            val p = file(ctx).readText().split("|")
            val st = p[0]
            val age = System.currentTimeMillis() - p[1].toLong()
            // a state nobody refreshes any more means the service process is gone
            val stale = when {
                st == "running" -> age > 6000
                st == "starting" -> age > 30000
                st == "stopping" -> age > 8000
                st.startsWith("error:") -> age > 60000
                else -> false
            }
            if (stale) return S("stopped", 0, 0, 0, 0)
            return S(st, p[2].toLong(), p[3].toLong(), p[4].toLong(), p[5].toLong())
        } catch (_: Exception) {
            return S("stopped", 0, 0, 0, 0)
        }
    }
}
