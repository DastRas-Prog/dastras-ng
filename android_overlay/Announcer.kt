package com.dastras.ng

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/** Fetches the customers' announcements (a small JSON file) and shows new ones as notifications. */
object Announcer {
    private const val CHANNEL = "dastras_news"

    // plain file instead of SharedPreferences: the app and the :vpn process both use it
    private fun seenFile(ctx: Context) = File(ctx.filesDir, "ann_seen.txt")

    private fun getSeen(ctx: Context): Int =
        try {
            seenFile(ctx).readText().trim().toInt()
        } catch (_: Exception) {
            -1
        }

    private fun putSeen(ctx: Context, v: Int) {
        try {
            seenFile(ctx).writeText(v.toString())
        } catch (_: Exception) {
        }
    }

    private fun fetch(urls: List<String>): String? {
        for (u in urls) {
            try {
                val c = URL(u).openConnection() as HttpURLConnection
                c.connectTimeout = 8000
                c.readTimeout = 8000
                c.useCaches = false
                c.setRequestProperty("User-Agent", "DastRasNG")
                if (c.responseCode == 200) {
                    val t = c.inputStream.bufferedReader().use { it.readText() }
                    JSONArray(t) // must be a valid array
                    return t
                }
            } catch (_: Exception) {
            }
        }
        return null
    }

    /** Returns the raw JSON (or null when offline). New items become notifications when [post] is true. */
    fun check(ctx: Context, urls: List<String>, post: Boolean): String? {
        val raw = fetch(urls) ?: return null
        try {
            val arr = JSONArray(raw)
            val seen = getSeen(ctx)
            var max = seen
            val fresh = ArrayList<JSONObject>()
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val id = o.optInt("id", -1)
                if (id > max) max = id
                if (id > seen) fresh.add(o)
            }
            if (seen == -1) {
                // first run: remember the current state, do not flood the user with old messages
                putSeen(ctx, max.coerceAtLeast(0))
                return raw
            }
            if (post) {
                fresh.sortBy { it.optInt("id") }
                for (o in fresh.takeLast(3)) {
                    show(ctx, 2000 + o.optInt("id"), o.optString("title").ifEmpty { "DastRas NG" }, o.optString("body"))
                }
            }
            if (max > seen) putSeen(ctx, max)
        } catch (_: Exception) {
        }
        return raw
    }

    /** Posts a normal (dismissible) notification. */
    fun show(ctx: Context, id: Int, title: String, body: String) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ctx.checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED
        ) return
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "DastRas", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val open = PendingIntent.getActivity(
            ctx, 0, Intent(ctx, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CHANNEL) else Notification.Builder(ctx)
        b.setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentIntent(open)
            .setAutoCancel(true)
        nm.notify(id, b.build())
    }
}
