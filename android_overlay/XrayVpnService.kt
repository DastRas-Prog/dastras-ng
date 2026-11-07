package com.dastras.ng

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.TrafficStats
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import libXray.DialerController
import libXray.LibXray
import org.json.JSONObject
import java.io.File

class XrayVpnService : VpnService(), DialerController {

    companion object {
        const val ACTION_START = "com.dastras.ng.START"
        const val ACTION_STOP = "com.dastras.ng.STOP"
        private const val CHANNEL_ID = "dastras_vpn"
        private const val NOTIF_ID = 1

        // bumped on every start so a late "kill the process" from an old stop never hits a new session
        @Volatile var generation = 0
    }

    private val lock = Any()
    private var tun: ParcelFileDescriptor? = null
    private var monitor: Thread? = null
    private var annThread: Thread? = null
    private val annUrls = ArrayList<String>()
    @Volatile private var monitoring = false
    @Volatile private var closed = false
    @Volatile private var xrayRunning = false
    @Volatile private var curState = "stopped" // stopped | starting | running | error:<message>
    @Volatile private var down = 0L
    @Volatile private var up = 0L
    @Volatile private var totDown = 0L
    @Volatile private var totUp = 0L
    private var lang = "fa"

    private fun setState(s: String) {
        curState = s
        VpnState.write(this, s, down, up, totDown, totUp)
    }

    // Called by libXray for every outbound socket so it bypasses the VPN.
    override fun protectFd(fd: Long): Boolean = protect(fd.toInt())

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            requestStop(false)
            return START_NOT_STICKY
        }
        generation++
        closed = false
        // read language early so the very first notification is localized
        try {
            lang = JSONObject(File(filesDir, "settings.json").readText()).optString("lang", "fa")
        } catch (_: Exception) {
        }
        showForeground()
        setState("starting")
        Thread { startCore() }.start()
        return START_NOT_STICKY
    }

    private fun invoke(method: String, payload: JSONObject = JSONObject()): JSONObject {
        val req = JSONObject()
            .put("apiVersion", 3)
            .put("method", method)
            .put("payload", payload)
        return JSONObject(LibXray.invoke(req.toString()))
    }

    /** Never blocks the caller: the real shutdown runs on its own thread. */
    fun requestStop(keepState: Boolean) {
        Thread { shutdown(keepState) }.start()
    }

    private fun startCore() {
        try {
            val datDir = File(filesDir, "dat").apply { mkdirs() }
            copyAsset("geoip.dat", datDir)
            copyAsset("geosite.dat", datDir)

            val cfgFile = File(filesDir, "config.json")
            val cfg = JSONObject(cfgFile.readText())
            // credentials must not stay on disk
            cfgFile.delete()

            var mode = "all"
            var ipv6 = true
            var mtu = 1500
            val pkgs = ArrayList<String>()
            val dns = ArrayList<String>()
            val setFile = File(filesDir, "settings.json")
            try {
                val pa = JSONObject(setFile.readText())
                mode = pa.optString("mode", "all")
                ipv6 = pa.optBoolean("ipv6", true)
                mtu = pa.optInt("mtu", 1500).coerceIn(1280, 1500)
                val arr = pa.optJSONArray("apps")
                if (arr != null) for (i in 0 until arr.length()) pkgs.add(arr.getString(i))
                val an = pa.optJSONArray("ann")
                if (an != null) for (i in 0 until an.length()) annUrls.add(an.getString(i))
                val d = pa.optJSONArray("dns")
                if (d != null) for (i in 0 until d.length()) dns.add(d.getString(i))
            } catch (_: Exception) {
            }
            setFile.delete()
            if (dns.isEmpty()) {
                dns.add("1.1.1.1")
                dns.add("8.8.8.8")
            }

            val builder = Builder()
                .setSession("DastRas NG")
                .setMtu(mtu)
                .addAddress("172.19.0.1", 30)
                .addRoute("0.0.0.0", 0)
            if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)
            if (ipv6) {
                builder.addAddress("fdfe:dcba:9876::1", 126).addRoute("::", 0)
            }
            for (s in dns.take(2)) builder.addDnsServer(s)

            // Per-app proxy: all | include (only chosen apps) | exclude (all except chosen)
            if (mode == "include" && pkgs.isNotEmpty()) {
                for (p in pkgs) {
                    try {
                        builder.addAllowedApplication(p)
                    } catch (_: Exception) {
                    }
                }
            } else {
                try {
                    builder.addDisallowedApplication(packageName)
                } catch (_: Exception) {
                }
                if (mode == "exclude") {
                    for (p in pkgs) {
                        try {
                            builder.addDisallowedApplication(p)
                        } catch (_: Exception) {
                        }
                    }
                }
            }

            val pfd = builder.establish() ?: throw IllegalStateException("VPN establish failed")
            // Xray gets its own duplicate of the tunnel fd; we keep the original so we can
            // always close it ourselves (a detached fd could never be closed from here).
            val fd = pfd.dup().detachFd()
            synchronized(lock) {
                if (closed) { // a stop arrived while the tunnel was being created
                    try {
                        pfd.close()
                    } catch (_: Throwable) {
                    }
                    try {
                        ParcelFileDescriptor.adoptFd(fd).close()
                    } catch (_: Throwable) {
                    }
                    stopSelf()
                    return
                }
                tun = pfd
            }

            val env = cfg.optJSONObject("env") ?: JSONObject()
            env.put("xray.tun.fd", fd.toString())
            env.put("xray.location.asset", datDir.absolutePath)
            cfg.put("env", env)

            LibXray.registerDialerController(this)
            LibXray.registerListenerController(this)
            try {
                LibXray.setDNS(this, dns[0] + ":53")
            } catch (_: Throwable) {
            }

            val resp = invoke("runXray", JSONObject().put("xrayJson", cfg.toString()))
            if (!resp.optBoolean("success", false)) {
                throw IllegalStateException(resp.optString("error", "runXray failed"))
            }
            xrayRunning = true
            if (closed) { // stop requested while Xray was starting
                shutdown(false)
                return
            }
            setState("running")
            startMonitor()
            startAnnouncements()
        } catch (t: Throwable) {
            setState("error:" + (t.message ?: t.javaClass.simpleName))
            shutdown(true)
        }
    }

    // Our own process owns every socket that carries proxied traffic, so the
    // per-UID counters give an accurate, real-time throughput figure.
    private fun startMonitor() {
        monitoring = true
        val uid = android.os.Process.myUid()
        val rx0 = TrafficStats.getUidRxBytes(uid).coerceAtLeast(0)
        val tx0 = TrafficStats.getUidTxBytes(uid).coerceAtLeast(0)
        var lastRx = rx0
        var lastTx = tx0
        var lastT = SystemClock.elapsedRealtime()
        down = 0; up = 0; totDown = 0; totUp = 0
        monitor = Thread {
            while (monitoring) {
                try {
                    Thread.sleep(1000)
                } catch (_: InterruptedException) {
                    break
                }
                val rx = TrafficStats.getUidRxBytes(uid)
                val tx = TrafficStats.getUidTxBytes(uid)
                if (rx >= 0 && tx >= 0) {
                    val now = SystemClock.elapsedRealtime()
                    val dt = (now - lastT).coerceAtLeast(1) / 1000.0
                    down = ((rx - lastRx) / dt).toLong().coerceAtLeast(0)
                    up = ((tx - lastTx) / dt).toLong().coerceAtLeast(0)
                    totDown = (rx - rx0).coerceAtLeast(0)
                    totUp = (tx - tx0).coerceAtLeast(0)
                    lastRx = rx
                    lastTx = tx
                    lastT = now
                }
                VpnState.write(this, curState, down, up, totDown, totUp) // heartbeat for the app
                updateNotification()
            }
        }.also { it.start() }
    }

    private fun startAnnouncements() {
        if (annUrls.isEmpty()) return
        annThread = Thread {
            try {
                Thread.sleep(20_000)
                while (monitoring) {
                    try {
                        Announcer.check(this, annUrls, true)
                    } catch (_: Exception) {
                    }
                    Thread.sleep(10 * 60 * 1000L)
                }
            } catch (_: InterruptedException) {
            }
        }.also { it.start() }
    }

    /**
     * Tears everything down. Safe to call more than once and from any thread. The service is
     * always stopped at the end, which also removes the VPN key icon from the status bar.
     */
    @Suppress("DEPRECATION")
    private fun shutdown(keepState: Boolean) {
        synchronized(lock) {
            closed = true
            monitoring = false
            monitor?.interrupt()
            monitor = null
            annThread?.interrupt()
            annThread = null
            down = 0; up = 0; totDown = 0; totUp = 0
            if (xrayRunning) {
                // stopXray must never be able to hang the shutdown
                val t = Thread {
                    try {
                        invoke("stopXray")
                    } catch (_: Throwable) {
                    }
                }
                t.start()
                try {
                    t.join(4000)
                } catch (_: InterruptedException) {
                }
                xrayRunning = false
            }
            try {
                LibXray.resetDNS()
            } catch (_: Throwable) {
            }
            try {
                tun?.close()
            } catch (_: Throwable) {
            }
            tun = null
            if (!keepState) setState("stopped")
        }
        try {
            stopForeground(true)
        } catch (_: Throwable) {
        }
        stopSelf()
        // This service runs in its own process (:vpn). Ending that process guarantees that every
        // file descriptor of the tunnel is closed, so the VPN key icon always disappears.
        val gen = generation
        Thread {
            try {
                Thread.sleep(300)
            } catch (_: InterruptedException) {
            }
            if (gen == generation) android.os.Process.killProcess(android.os.Process.myPid())
        }.start()
    }

    override fun onRevoke() {
        requestStop(false)
    }

    override fun onDestroy() {
        if (!closed) Thread { shutdown(false) }.start()
        super.onDestroy()
    }

    private fun copyAsset(name: String, dir: File) {
        val out = File(dir, name)
        val updated = packageManager.getPackageInfo(packageName, 0).lastUpdateTime
        if (out.exists() && out.length() > 0 && out.lastModified() >= updated) return
        assets.open("flutter_assets/assets/$name").use { input ->
            out.outputStream().use { input.copyTo(it) }
        }
    }

    private fun fmtRate(b: Long): String = fmt(b) + "/s"

    private fun fmt(b: Long): String {
        val u = arrayOf("B", "KB", "MB", "GB", "TB")
        var v = b.toDouble()
        var i = 0
        while (v >= 1024 && i < u.size - 1) {
            v /= 1024
            i++
        }
        return if (i <= 1) "${v.toLong()} ${u[i]}" else String.format(java.util.Locale.US, "%.1f %s", v, u[i])
    }

    private fun buildNotification(): Notification {
        val fa = lang == "fa"
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, XrayVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        val running = curState == "running"
        val text = if (running) "↓ ${fmtRate(down)}    ↑ ${fmtRate(up)}"
        else (if (fa) "در حال اتصال..." else "Connecting...")
        val sub = if (running) {
            (if (fa) "مصرف: " else "Used: ") + fmt(totDown + totUp)
        } else ""
        b.setContentTitle(if (!running) "DastRas NG" else if (fa) "DastRas NG — متصل" else "DastRas NG — Connected")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
        if (sub.isNotEmpty()) b.setSubText(sub)
        @Suppress("DEPRECATION")
        b.addAction(
            android.R.drawable.ic_menu_close_clear_cancel,
            if (fa) "قطع اتصال" else "Disconnect",
            stop
        )
        return b.build()
    }

    private fun updateNotification() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification())
    }

    private fun showForeground() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "DastRas NG", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val n = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }
}
