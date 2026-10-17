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
    private val issued = mutableSetOf<String>()
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
        val id = data.optString("interactionId").ifEmpty { data.optString("id", UUID.randomUUID().toString()) }
        val target = data.optString("interactionId")
        if (target.isNotEmpty() && data.optString("kind") in setOf("question", "approval")) {
            val request = (LocalConnection.snapshot()["interactions"] as? List<*>)?.filterIsInstance<Map<*, *>>()?.firstOrNull { it["id"] == target }
            if (request != null && request["status"] != "pending") return
        }
        if (!issued.add(id)) return
        val kind = data.optString("kind")
        val decision = kind == "question" || kind == "approval"
        val session = data.optString("sessionId").ifEmpty { null }
        val interaction = data.optString("interactionId").ifEmpty { null }
        val builder = Notification.Builder(context, if (decision) DECISIONS else ACTIVITY)
            .setSmallIcon(R.drawable.ic_notification).setColor(Color.rgb(111, 108, 213))
            .setContentTitle(data.optString("title", "Omputer"))
            .setContentText(data.optString("body"))
            .setStyle(Notification.BigTextStyle().bigText(data.optString("body")))
            .setContentIntent(openIntent(context, id, session, interaction)).setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setPublicVersion(publicNotification(context))
            .setCategory(if (decision) Notification.CATEGORY_MESSAGE else Notification.CATEGORY_STATUS)
        if (interaction != null && kind != "approval") {
            val request = (LocalConnection.snapshot()["interactions"] as? List<*>)?.filterIsInstance<Map<*, *>>()?.firstOrNull { it["id"] == interaction }
            if (request?.get("method") in listOf("input", "editor")) {
                val intent = Intent(context, NotificationActionReceiver::class.java).setAction("omputer.reply")
                    .putExtra("interactionId", interaction).putExtra("sessionId", session).putExtra("commandId", UUID.randomUUID().toString())
                val pending = PendingIntent.getBroadcast(context, notificationId(id), intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
                val reply = RemoteInput.Builder("reply").setLabel("Cevabın").build()
                builder.addAction(Notification.Action.Builder(null, "Cevapla", pending).addRemoteInput(reply).build())
            }
        }
        context.getSystemService(NotificationManager::class.java).notify(notificationId(id), builder.build())
    }
    @Synchronized fun reconcile(context: Context, snapshot: JSONObject) {
        val requests = snapshot.optJSONArray("interactions") ?: return
        for (index in 0 until requests.length()) {
            val request = requests.optJSONObject(index) ?: continue
            val id = request.optString("id")
            if (request.optString("status") != "pending") { cancelInteraction(context, id); continue }
            if (id in issued) continue
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
        val pending = goAsync()
        LocalConnection.requestAsync("POST", "/v1/commands", mapOf(
            "id" to (intent.getStringExtra("commandId") ?: UUID.randomUUID().toString()),
            "sessionId" to intent.getStringExtra("sessionId"), "action" to "interaction.respond",
            "payload" to mapOf("interactionId" to interaction, "value" to text))
        ) { _, error ->
            if (error == null) LocalNotifications.cancelInteraction(context, interaction)
            else LocalNotifications.post(context, JSONObject().put("id", UUID.randomUUID().toString()).put("kind", "error")
                .put("title", "Cevap iletilemedi").put("body", error.message ?: "Uygulamayı açıp bağlantıyı kontrol et.")
                .put("sessionId", intent.getStringExtra("sessionId")).put("interactionId", interaction))
            pending.finish()
        }
    }
}
