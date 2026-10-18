package dev.omputer.omputer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Color
import org.json.JSONObject
import java.util.UUID

internal object LocalNotifications {
    private const val DECISIONS = "omputer.decisions"
    private const val ACTIVITY = "omputer.activity"
    const val CONNECTION = "omputer.connection"
    const val CONNECTION_ID = 2
    private val issued = linkedMapOf<String, Long>()
    private const val MAX_NOTIFICATIONS = 48
    fun initialize(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannels(listOf(
            NotificationChannel(DECISIONS, "Sorular ve izinler", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "OMP’nin senden cevap beklediği kararlar"; enableVibration(true)
            },
            NotificationChannel(ACTIVITY, "Çalışma durumu", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Yanıtlar ve çalışma hataları"
            },
            NotificationChannel(CONNECTION, "Yerel PC bağlantısı", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Bulutsuz arka plan bağlantısının durumu"; setShowBadge(false)
            }
        ))
    }
    private fun notificationId(id: String) = 100 + (id.hashCode() and 0x3fffffff)
    private fun openIntent(context: Context, id: String, session: String?, interaction: String?): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra("sessionId", session).putExtra("interactionId", interaction)
        return PendingIntent.getActivity(context, notificationId(id), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    private fun publicNotification(context: Context): Notification = Notification.Builder(context, DECISIONS)
        .setSmallIcon(R.drawable.ic_notification).setContentTitle("Omputer")
        .setContentText("PC’de bir oturum senden cevap bekliyor.").build()
    fun connection(context: Context): Notification {
        val state = LocalConnection.connection()
        val text = when {
            state["paired"] != true -> "Bilgisayar eşleştirilmedi · bağlantı yapılandırılmadı"
            state["connected"] == true -> "${state["serverName"] ?: "PC"} · doğrudan, şifreli bağlantı"
            else -> "Bilgisayara ulaşılamıyor · otomatik yeniden deneniyor"
        }
        val stop = Intent(context, NotificationActionReceiver::class.java).setAction("omputer.stop")
        val pending = PendingIntent.getBroadcast(context, 3, stop, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(context, CONNECTION).setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(if (state["connected"] == true) "Omputer bağlı" else "Omputer bağlantısı bekleniyor").setContentText(text)
            .setContentIntent(openIntent(context, "connection", null, null)).setOngoing(true).setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE).addAction(Notification.Action.Builder(null, "Bağlantıyı kapat", pending).build()).build()
    }
    @Synchronized fun post(context: Context, data: JSONObject) {
        if (!LocalConnection.notificationsAuthorized()) return
        val kind = data.optString("kind")
        if (!LocalConnection.notificationEnabled(data.optString("sessionId").ifBlank { null }, data.optString("projectId").ifBlank { null }, kind)) return
        val decision = kind == "question" || kind == "approval"
        val interaction = data.optString("interactionId").ifBlank { null }
        val request = interaction?.let { LocalConnection.pendingInteraction(it) }
        if (decision && (request == null || !DecisionPolicy.pending(request))) return
        val id = if (decision && interaction != null) interaction else data.optString("id").ifBlank { UUID.randomUUID().toString() }
        val manager = context.getSystemService(NotificationManager::class.java)
        val active = manager.activeNotifications
        if (id in issued && active.any { it.id == notificationId(id) }) return
        while (issued.size >= 256) issued.remove(issued.keys.first())
        issued[id] = System.currentTimeMillis()
        active.filter { it.id != CONNECTION_ID }.sortedBy { it.postTime }.dropLast(MAX_NOTIFICATIONS - 1).forEach { manager.cancel(it.id) }
        val session = data.optString("sessionId").ifBlank { null }
        val builder = Notification.Builder(context, if (decision) DECISIONS else ACTIVITY)
            .setSmallIcon(R.drawable.ic_notification).setColor(Color.rgb(111, 108, 213))
            .setContentTitle(data.optString("title", "Omputer"))
            .setContentText(data.optString("body"))
            .setStyle(Notification.BigTextStyle().bigText(data.optString("body")))
            .setContentIntent(openIntent(context, id, session, interaction)).setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setPublicVersion(publicNotification(context))
            .setCategory(if (decision) Notification.CATEGORY_MESSAGE else Notification.CATEGORY_STATUS)
        if (decision && request != null) {
            val expires = request.optString("expiresAt")
            if (expires.isNotBlank() && expires != "null") {
                val remaining = java.time.Duration.between(java.time.Instant.now(), java.time.Instant.parse(expires)).toMillis()
                if (remaining <= 0) return
                builder.setTimeoutAfter(remaining)
            }
            if (request.optString("method") in listOf("input", "editor")) {
                val intent = Intent(context, NotificationActionReceiver::class.java).setAction("omputer.reply")
                    .putExtra("interactionId", interaction).putExtra("sessionId", session)
                    .putExtra("deviceId", LocalConnection.notificationIdentity()).putExtra("commandId", UUID.randomUUID().toString())
                val pending = PendingIntent.getBroadcast(context, notificationId(id), intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
                val reply = RemoteInput.Builder("reply").setLabel("Cevabın").build()
                builder.addAction(Notification.Action.Builder(null, "Cevapla", pending).addRemoteInput(reply).build())
            }
        }
        manager.notify(notificationId(id), builder.build())
    }
    @Synchronized fun reconcile(context: Context, snapshot: JSONObject) {
        val requests = snapshot.optJSONArray("interactions") ?: return
        val pending = linkedMapOf<String, JSONObject>()
        for (index in 0 until requests.length()) {
            val request = requests.optJSONObject(index) ?: continue
            val id = request.optString("id")
            if (id.isNotBlank() && DecisionPolicy.pending(request)) pending[id] = request
            else cancelInteraction(context, id)
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        val pendingIds = pending.keys.map(::notificationId).toSet()
        manager.activeNotifications.filter { it.notification.channelId == DECISIONS && it.id !in pendingIds }.forEach { manager.cancel(it.id) }
        pending.values.toList().takeLast(MAX_NOTIFICATIONS).forEach { request ->
            val id = request.getString("id")
            post(context, JSONObject().put("id", id).put("interactionId", id)
                .put("sessionId", request.optString("sessionId"))
                .put("kind", if (request.optString("method") == "approval") "approval" else "question")
                .put("title", request.optString("title", "OMP cevap bekliyor"))
                .put("body", request.optString("message", "Soruyu açıp kararını paylaş.")))
        }
    }
    @Synchronized fun cancelInteraction(context: Context, id: String) {
        issued.remove(id)
        context.getSystemService(NotificationManager::class.java).cancel(notificationId(id))
    }
    @Synchronized fun cancelAll(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.activeNotifications.filter { it.id != CONNECTION_ID }.forEach { manager.cancel(it.id) }
        issued.clear()
    }
}

class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        LocalConnection.initialize(context)
        if (intent.action == "omputer.stop") {
            LocalConnection.setBackground(false)
            context.stopService(Intent(context, ConnectionService::class.java))
            if (!LocalConnection.activityVisible) LocalConnection.disconnect()
            return
        }
        if (intent.action != "omputer.reply") return
        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence("reply")?.toString() ?: return
        val interaction = intent.getStringExtra("interactionId") ?: return
        fun failed(error: Throwable) = LocalNotifications.post(context, JSONObject().put("id", UUID.randomUUID().toString()).put("kind", "error")
            .put("title", "Cevap iletilemedi").put("body", error.message ?: "Uygulamayı açıp bağlantıyı kontrol et.")
            .put("sessionId", intent.getStringExtra("sessionId")).put("interactionId", interaction))
        try {
            if (intent.getStringExtra("deviceId") != LocalConnection.notificationIdentity()) throw ApiFailure("connection_changed", "Bilgisayar eşleştirmesi değişti. Uygulamadan güncel soruyu aç.")
            LocalConnection.requirePendingInteraction(interaction)
        } catch (error: Exception) { LocalNotifications.cancelInteraction(context, interaction); failed(error); return }
        val pending = goAsync()
        LocalConnection.notificationReply(mapOf(
            "id" to (intent.getStringExtra("commandId") ?: UUID.randomUUID().toString()),
            "sessionId" to intent.getStringExtra("sessionId"), "action" to "interaction.respond",
            "payload" to mapOf("interactionId" to interaction, "value" to text)),
            identity = intent.getStringExtra("deviceId")
        ) { value, error ->
            try {
                if (error != null) failed(error)
                else {
                    val response = JSONObject(value as? Map<*, *> ?: emptyMap<String, Any?>())
                    val envelope = response.optJSONObject("result") ?: response
                    if (DecisionPolicy.finalSuccess(envelope)) LocalNotifications.cancelInteraction(context, interaction)
                    else LocalNotifications.post(context, JSONObject().put("id", "reply:${intent.getStringExtra("commandId")}")
                        .put("kind", "activity").put("title", "Cevap sonucu bekleniyor")
                        .put("body", "PC işlemi aldı; kesin sonuç için uygulamayı aç. Cevap otomatik tekrar gönderilmeyecek.")
                        .put("sessionId", intent.getStringExtra("sessionId")))
                }
            } finally { pending.finish() }
        }
    }
}
