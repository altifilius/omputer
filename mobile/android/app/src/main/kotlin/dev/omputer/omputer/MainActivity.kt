package dev.omputer.omputer

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var notificationResult: MethodChannel.Result? = null
    private var eventListener: ((Map<String, Any?>) -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        LocalConnection.initialize(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "omputer/connection").setMethodCallHandler(::handleMethod)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "omputer/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                eventListener?.let { LocalConnection.removeListener(it) }
                val listener: (Map<String, Any?>) -> Unit = { event -> sink.success(event) }
                eventListener = listener
                LocalConnection.addListener(listener)
            }
            override fun onCancel(arguments: Any?) {
                eventListener?.let { LocalConnection.removeListener(it) }; eventListener = null
            }
        })
        handleNavigation(intent)
    }
    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        fun async(operation: () -> Any?) = LocalConnection.execute(operation) { value, error ->
            if (error != null) result.error((error as? ApiFailure)?.code ?: "local_error", error.message ?: "İşlem tamamlanamadı.", null)
            else result.success(value)
        }
        fun pairing(operation: () -> Any?) = LocalConnection.executePairing(operation) { value, error ->
            if (error != null) result.error((error as? ApiFailure)?.code ?: "local_error", error.message ?: "Eşleştirme tamamlanamadı.", null)
            else result.success(value)
        }
        try {
            when (call.method) {
                "discover" -> result.success(LocalConnection.discover(call.argument<Boolean>("enabled") == true))
                "pairRequest" -> pairing { LocalConnection.pairRequest(call.argument<String>("computerId") ?: error("Bilgisayar seçilmedi."), call.argument<String>("name") ?: Build.MODEL, call.argument<Boolean>("background") == true) }
                "pairPoll" -> pairing { LocalConnection.pairPoll() }
                "pairCancel" -> { LocalConnection.pairCancel(); result.success(null) }
                "pair" -> pairing { LocalConnection.pair(call.argument<String>("bundle") ?: error("Eşleştirme verisi eksik."), call.argument<String>("name") ?: Build.MODEL) }
                "connection" -> result.success(LocalConnection.connection())
                "snapshot" -> async { LocalConnection.snapshot() }
                "preferences" -> result.success(LocalConnection.preferences())
                "theme" -> { LocalConnection.setTheme(call.argument<String>("mode") ?: "system"); result.success(null) }
                "request" -> LocalConnection.requestAsync(call.argument<String>("method") ?: "GET", call.argument<String>("path") ?: error("İstek yolu eksik."), call.argument<Map<*, *>>("body")) { value, failure ->
                    if (failure != null) result.error((failure as? ApiFailure)?.code ?: "local_error", failure.message, null)
                    else result.success(value)
                }
                "connect" -> { LocalConnection.connect(); result.success(LocalConnection.connection()) }
                "background" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    if (enabled && LocalConnection.connection()["paired"] != true) throw ApiFailure("not_paired", "Önce PC ile eşleştir.")
                    LocalConnection.setBackground(enabled)
                    val service = Intent(this, ConnectionService::class.java)
                    if (enabled) {
                        try { startForegroundService(service) }
                        catch (error: Exception) { LocalConnection.setBackground(false); throw error }
                    } else { stopService(service); LocalConnection.connect() }
                    result.success(LocalConnection.connection())
                }
                "notifications" -> {
                    if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) result.success(true)
                    else if (notificationResult != null) result.error("permission_pending", "Bildirim izni isteği zaten açık.", null)
                    else { notificationResult = result; requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 42) }
                }
                "batterySettings" -> {
                    startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)); result.success(null)
                }
                "forget" -> async { stopService(Intent(this, ConnectionService::class.java)); LocalConnection.forget(); null }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error((error as? ApiFailure)?.code ?: "local_error", error.message ?: "İşlem tamamlanamadı.", null)
        }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 42) { notificationResult?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED); notificationResult = null }
    }
    private fun handleNavigation(value: Intent?) {
        if (value == null) return
        val uri = value.data
        if (uri?.scheme == "omputer" && uri.host == "pair") LocalConnection.navigate(mapOf("bundle" to uri.toString()))
        else {
            val session = value.getStringExtra("sessionId")
            val interaction = value.getStringExtra("interactionId")
            if (session != null || interaction != null) LocalConnection.navigate(mapOf("sessionId" to session, "interactionId" to interaction))
        }
        value.data = null
        value.removeExtra("sessionId"); value.removeExtra("interactionId")
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handleNavigation(intent) }
    override fun onStart() {
        super.onStart()
        LocalConnection.initialize(applicationContext)
        LocalConnection.activityVisible = true
        if (LocalConnection.connection()["paired"] == true) {
            LocalConnection.connect()
            if (LocalConnection.isBackground()) {
                try { startForegroundService(Intent(this, ConnectionService::class.java)) }
                catch (error: Exception) { LocalConnection.backgroundUnavailable(error.message ?: "Android arka plan bağlantısına izin vermedi.") }
            }
        }
    }
    override fun onStop() {
        LocalConnection.activityVisible = false
        if (!LocalConnection.isBackground()) LocalConnection.disconnect()
        LocalConnection.discover(false)
        super.onStop()
    }
    override fun onDestroy() {
        eventListener?.let { LocalConnection.removeListener(it) }; eventListener = null
        notificationResult?.error("activity_closed", "İzin ekranı kapandı.", null); notificationResult = null
        super.onDestroy()
    }
}
