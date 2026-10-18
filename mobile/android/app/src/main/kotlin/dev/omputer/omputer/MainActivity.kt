package dev.omputer.omputer

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.app.Activity
import android.content.ClipData
import android.net.Uri
import android.provider.MediaStore
import androidx.core.content.FileProvider
import java.io.File
import java.util.UUID
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var notificationResult: MethodChannel.Result? = null
    private var eventListener: ((Map<String, Any?>) -> Unit)? = null
    private var imageResult: MethodChannel.Result? = null
    private var imageIdentity: String? = null
    private var cameraFile: File? = null
    private var cameraUri: Uri? = null

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
        fun local(operation: () -> Any?) {
            val identity = LocalConnection.localIdentity()
            async { LocalConnection.withIdentity(identity, operation) }
        }
        try {
            when (call.method) {
                "discover" -> result.success(LocalConnection.discover(call.argument<Boolean>("enabled") == true))
                "pairRequest" -> pairing { LocalConnection.pairRequest(call.argument<String>("computerId") ?: error("Bilgisayar seçilmedi."), call.argument<String>("name") ?: Build.MODEL, call.argument<Boolean>("background") == true) }
                "pairPoll" -> pairing { LocalConnection.pairPoll() }
                "pairCancel" -> { LocalConnection.pairCancel(); result.success(null) }
                "previewBundle" -> pairing { LocalConnection.previewBundle(call.argument<String>("bundle") ?: error("Eşleştirme verisi eksik.")) }
                "pair" -> pairing { LocalConnection.pair(call.argument<String>("bundle") ?: error("Eşleştirme verisi eksik."), call.argument<String>("name") ?: Build.MODEL) }
                "connection" -> result.success(LocalConnection.connection())
                "snapshot" -> async { LocalConnection.snapshot() }
                "preferences" -> result.success(LocalConnection.preferences())
                "theme" -> { LocalConnection.setTheme(call.argument<String>("mode") ?: "system"); result.success(null) }
                "localState" -> local { LocalConnection.localState() }
                "localStateSet" -> local { LocalConnection.localStateSet(call.argument<String>("section") ?: error("Bölüm eksik."), call.argument<String>("key") ?: error("Anahtar eksik."), call.argument<Any>("value")) }
                "draftLoad" -> local { LocalConnection.draftLoad(call.argument<String>("key") ?: error("Anahtar eksik.")) }
                "draftList" -> local { LocalConnection.draftList() }
                "draftSave" -> local { LocalConnection.draftSave(call.argument<String>("key") ?: error("Anahtar eksik."), call.argument<Map<*, *>>("value") ?: error("Taslak eksik.")); null }
                "draftDelete" -> local { LocalConnection.draftDelete(call.argument<String>("key") ?: error("Anahtar eksik.")); null }
                "operationSave" -> local { LocalConnection.operationSave(call.argument<Map<*, *>>("operation") ?: error("İşlem eksik.")); null }
                "operationList" -> local { LocalConnection.operationList() }
                "operationRemove" -> local { LocalConnection.operationRemove(call.argument<String>("id") ?: error("Kimlik eksik.")); null }
                "pickImages" -> pickImages(call.argument<Boolean>("camera") == true, result)
                "removeAttachment" -> local { LocalConnection.removeAttachment(call.argument<String>("id") ?: error("Kimlik eksik.")); null }
                "sharedImages" -> local { LocalConnection.sharedImages() }
                "shareExport" -> shareExport(call, result)
                "request" -> LocalConnection.requestAsync(call.argument<String>("method") ?: "GET", call.argument<String>("path") ?: error("İstek yolu eksik."), call.argument<Map<*, *>>("body")) { value, failure ->
                    if (failure != null) result.error((failure as? ApiFailure)?.code ?: "local_error", failure.message, null)
                    else result.success(value)
                }
                "connect" -> { if (call.argument<Boolean>("force") == true) LocalConnection.reconnect() else LocalConnection.connect(); result.success(LocalConnection.connection()) }
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
                    if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
                        LocalConnection.notificationPermissionChanged(); result.success(LocalConnection.notificationsAllowed())
                    }
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
        if (requestCode == 42) {
            LocalConnection.notificationPermissionChanged()
            notificationResult?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED); notificationResult = null
        }
        if (requestCode == 45) {
            val result = imageResult ?: return
            if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
                imageResult = null; imageIdentity = null; result.success(emptyList<Any>())
            } else {
                val identity = imageIdentity
                imageResult = null
                try {
                    if (identity != LocalConnection.localIdentity()) throw ApiFailure("connection_changed", "Eşleştirme değişti; görsel eklenmedi.")
                    pickImages(true, result)
                } catch (error: Exception) { result.error((error as? ApiFailure)?.code ?: "image_error", error.message, null) }
            }
        }
    }
    private fun pickImages(camera: Boolean, result: MethodChannel.Result) {
        if (imageResult != null) throw ApiFailure("picker_pending", "Görsel seçimi zaten açık.")
        imageIdentity = LocalConnection.localIdentity()
        imageResult = result
        if (camera && checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), 45); return
        }
        try {
            val intent = if (camera) {
                val directory = File(cacheDir, "camera").apply { check(isDirectory || mkdirs()) }
                val file = File(directory, "${UUID.randomUUID()}.jpg").also { cameraFile = it }
                val uri = FileProvider.getUriForFile(this, "$packageName.files", file).also { cameraUri = it }
                Intent(MediaStore.ACTION_IMAGE_CAPTURE).putExtra(MediaStore.EXTRA_OUTPUT, uri)
                    .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    .apply { clipData = ClipData.newRawUri("Omputer camera", uri) }
            } else Intent(Intent.ACTION_OPEN_DOCUMENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE)
                .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            @Suppress("DEPRECATION")
            startActivityForResult(intent, if (camera) 44 else 43)
        } catch (error: Exception) {
            imageResult = null; imageIdentity = null; cleanupCamera(); throw error
        }
    }
    private fun cleanupCamera() {
        cameraUri?.let { revokeUriPermission(it, Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        cameraFile?.delete(); cameraFile = null; cameraUri = null
    }
    @Deprecated("Android activity result compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode !in setOf(43, 44)) return
        val result = imageResult ?: run { cleanupCamera(); return }
        val identity = imageIdentity
        if (resultCode != Activity.RESULT_OK) { imageResult = null; imageIdentity = null; cleanupCamera(); result.success(emptyList<Any>()); return }
        val uris = try { if (requestCode == 44) listOfNotNull(cameraUri) else intentUris(data) } catch (error: Exception) {
            imageResult = null; imageIdentity = null; cleanupCamera(); result.error("image_error", error.message, null); return
        }
        LocalConnection.execute({
            if (identity == null) throw ApiFailure("connection_changed", "Eşleştirme değişti.")
            LocalConnection.importImages(identity, uris)
        }) { value, error ->
            if (imageResult !== result) { cleanupCamera(); return@execute }
            imageResult = null; imageIdentity = null
            cleanupCamera()
            if (error != null) result.error((error as? ApiFailure)?.code ?: "image_error", error.message, null) else result.success(value)
        }
    }
    private fun intentUris(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()
        val uris = mutableListOf<Uri>()
        intent.clipData?.let { clip ->
            require(clip.itemCount <= AttachmentLimits.MAX_COUNT) { "En fazla 8 görsel paylaş." }
            for (index in 0 until clip.itemCount) clip.getItemAt(index).uri?.let(uris::add)
        }
        @Suppress("DEPRECATION")
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let {
            require(it.size <= AttachmentLimits.MAX_COUNT) { "En fazla 8 görsel paylaş." }; uris.addAll(it)
        }
        @Suppress("DEPRECATION")
        intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::add)
        intent.data?.let(uris::add)
        return uris.distinct().also { require(it.size <= AttachmentLimits.MAX_COUNT) { "En fazla 8 görsel paylaş." } }
    }
    private fun receiveImages(intent: Intent): Boolean {
        if (intent.action !in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) return false
        val uris = try { intentUris(intent) } catch (error: Exception) {
            LocalConnection.navigate(mapOf("shareError" to error.message)); return true
        }
        intent.action = null; intent.clipData = null; intent.removeExtra(Intent.EXTRA_STREAM)
        val identity = try { LocalConnection.localIdentity() } catch (error: Exception) {
            LocalConnection.navigate(mapOf("shareError" to (error.message ?: "Önce bilgisayarla eşleştir."))); return true
        }
        LocalConnection.execute({
            require(uris.isNotEmpty()) { "Paylaşılan görsel yok." }
            LocalConnection.importImages(identity, uris, shared = true)
        }) { _, error ->
            LocalConnection.navigate(if (error == null) mapOf("sharedImages" to true) else mapOf("shareError" to error.message))
        }
        return true
    }
    private fun shareExport(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text") ?: error("Dışa aktarılacak metin eksik.")
        val mime = call.argument<String>("mimeType") ?: "text/plain"
        require(mime in setOf("text/plain", "text/markdown", "application/json")) { "Desteklenmeyen dışa aktarma türü." }
        val filename = call.argument<String>("filename") ?: "omputer-export.txt"
        require(filename.matches(Regex("[A-Za-z0-9._-]{1,128}")) && filename != "." && filename != "..") { "Geçersiz dosya adı." }
        LocalConnection.execute({
            val bytes = text.toByteArray(Charsets.UTF_8)
            require(bytes.size <= 8 * 1024 * 1024) { "Dışa aktarma çok büyük." }
            val directory = File(cacheDir, "exports").apply { check(isDirectory || mkdirs()) }
            directory.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 24 * 60 * 60 * 1000L }?.forEach { it.deleteRecursively() }
            val file = File(File(directory, UUID.randomUUID().toString()), filename)
            DurableLocalState.atomicWrite(file, bytes)
            FileProvider.getUriForFile(this, "$packageName.files", file)
        }) { value, error ->
            if (error != null) result.error("export_error", error.message, null)
            else try {
                val uri = value as Uri
                val send = Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM, uri)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).apply { clipData = ClipData.newRawUri(filename, uri) }
                startActivity(Intent.createChooser(send, "Yerel kopyayı paylaş")); result.success(null)
            } catch (failure: Exception) { result.error("export_error", failure.message, null) }
        }
    }
    private fun handleNavigation(value: Intent?) {
        if (value == null) return
        if (receiveImages(value)) return
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
        imageResult?.error("activity_closed", "Görsel seçimi kapandı.", null); imageResult = null
        cleanupCamera()
        super.onDestroy()
    }
}
