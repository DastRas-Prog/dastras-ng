package com.dastras.ng

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.VpnService
import android.util.Base64
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import libXray.LibXray
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dastras/core")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "invoke" -> {
                        val req = call.arguments as String
                        Thread {
                            val res = try {
                                LibXray.invoke(req)
                            } catch (t: Throwable) {
                                "{\"success\":false,\"error\":\"" + (t.message ?: "error").replace("\"", "'") + "\"}"
                            }
                            runOnUiThread { result.success(res) }
                        }.start()
                    }
                    "start" -> {
                        val a = call.arguments as Map<*, *>
                        File(filesDir, "config.json").writeText(a["config"] as String)
                        val apps = JSONArray()
                        (a["apps"] as? List<*>)?.forEach { apps.put(it.toString()) }
                        File(filesDir, "perapp.json").writeText(
                            JSONObject().put("mode", (a["mode"] as? String) ?: "all").put("apps", apps).toString()
                        )
                        val intent = VpnService.prepare(this)
                        if (intent != null) {
                            pending = result
                            startActivityForResult(intent, REQ_VPN)
                        } else {
                            launchService()
                            result.success("ok")
                        }
                    }
                    "stop" -> {
                        startService(Intent(this, XrayVpnService::class.java).setAction(XrayVpnService.ACTION_STOP))
                        result.success("ok")
                    }
                    "status" -> result.success(XrayVpnService.state)
                    "apps" -> {
                        Thread {
                            val res = try {
                                listApps()
                            } catch (t: Throwable) {
                                "[]"
                            }
                            runOnUiThread { result.success(res) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun listApps(): String {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val seen = HashSet<String>()
        val out = JSONArray()
        for (ri in pm.queryIntentActivities(intent, 0)) {
            val pkg = ri.activityInfo.packageName
            if (pkg == packageName || !seen.add(pkg)) continue
            val bmp = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888)
            val d = ri.loadIcon(pm)
            d.setBounds(0, 0, 64, 64)
            d.draw(Canvas(bmp))
            val os = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 100, os)
            out.put(
                JSONObject()
                    .put("pkg", pkg)
                    .put("name", ri.loadLabel(pm).toString())
                    .put("icon", Base64.encodeToString(os.toByteArray(), Base64.NO_WRAP))
            )
        }
        return out.toString()
    }

    private fun launchService() {
        XrayVpnService.state = "starting"
        ContextCompat.startForegroundService(
            this,
            Intent(this, XrayVpnService::class.java).setAction(XrayVpnService.ACTION_START)
        )
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_VPN) {
            val r = pending
            pending = null
            if (resultCode == RESULT_OK) {
                launchService()
                r?.success("ok")
            } else {
                r?.success("denied")
            }
        } else {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    companion object {
        private const val REQ_VPN = 100
    }
}
