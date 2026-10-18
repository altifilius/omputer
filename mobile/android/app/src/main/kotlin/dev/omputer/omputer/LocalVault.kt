package dev.omputer.omputer

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal fun JSONObject.asMap(): Map<String, Any?> = keys().asSequence().associateWith { jsonValue(opt(it)) }
internal fun jsonValue(value: Any?): Any? = when (value) {
    null, JSONObject.NULL -> null
    is JSONObject -> value.asMap()
    is JSONArray -> (0 until value.length()).map { jsonValue(value.opt(it)) }
    else -> value
}

internal class LocalVault(context: Context) {
    private val preferences = context.getSharedPreferences("omputer.local", Context.MODE_PRIVATE)
    private val cache = File(context.filesDir, "snapshot.json")
    val durable = DurableLocalState(File(context.filesDir, "local-state"))
    val attachments = ImageAttachments(context)
    @Volatile var lastSyncAt: String? = preferences.getString("lastSyncAt", null)
        private set
    private val responses = ResponseCache(File(context.filesDir, "responses"), identity = preferences.getString("cacheIdentity", null))
    private val keyAlias = "omputer.device.v1"
    private val cacheLock = Any()
    private val pendingLock = Any()
    private val cacheWorker = java.util.concurrent.Executors.newSingleThreadScheduledExecutor()
    private var cacheScheduled = false
    private var cacheRevision = 0
    private var pendingSnapshot: JSONObject? = null
    private val pendingResponses = linkedMapOf<String, JSONObject>()
    private val pendingMessages = linkedMapOf<Pair<String, String>, JSONObject>()
    private val pendingResets = linkedSetOf<String?>()
    private var pendingChars = 0
    @Volatile var sequence: Long = 0
    @Volatile var messagesRevision: Long = 0
        private set

    private fun scheduleCache() {
        if (cacheScheduled) return
        cacheScheduled = true
        cacheWorker.schedule({ flushCache() }, 250, java.util.concurrent.TimeUnit.MILLISECONDS)
    }
    private fun flushCache() {
        synchronized(cacheLock) {
            val batch = synchronized(pendingLock) {
                cacheScheduled = false
                val work = CacheBatch(cacheRevision, pendingSnapshot, pendingResponses.toMap(), pendingMessages.toMap(), pendingResets.toSet())
                pendingSnapshot = null; pendingResponses.clear(); pendingMessages.clear(); pendingResets.clear(); pendingChars = 0
                work
            }
            if (batch.revision != cacheRevision) return
            // Cache failure must not discard an authenticated answer or stop live decisions.
            batch.resets.forEach { try { responses.resetMessages(it) } catch (_: Exception) {} }
            batch.responses.forEach { (path, value) -> try { responses.put(path, value) } catch (_: Exception) {} }
            batch.messages.forEach { (key, value) -> try { responses.updateMessage(key.first, value) } catch (_: Exception) {} }
            batch.snapshot?.let { value -> try {
                val stored = JSONObject().also { copy -> value.keys().forEach { copy.put(it, value.opt(it)) } }
                preferences.getString("cacheIdentity", null)?.let { stored.put("_deviceId", it) }
                lastSyncAt?.let { stored.put("_lastSyncAt", it) }
                val raw = stored.toString()
                if (raw.length <= MAX_SNAPSHOT_BYTES && raw.toByteArray(Charsets.UTF_8).size <= MAX_SNAPSHOT_BYTES) {
                    val temporary = File(cache.parentFile, "snapshot.tmp")
                    temporary.writeText(raw)
                    check(temporary.renameTo(cache)) { "Yerel proje hafızası kaydedilemedi." }
                }
                preferences.edit().putString("lastSyncAt", lastSyncAt).commit()
            } catch (_: Exception) {} }
        }
    }
    private data class CacheBatch(val revision: Int, val snapshot: JSONObject?, val responses: Map<String, JSONObject>,
        val messages: Map<Pair<String, String>, JSONObject>, val resets: Set<String?>)

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(keyAlias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(keyAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }

    @Synchronized fun credentials(): JSONObject? {
        val encoded = preferences.getString("credentials", null) ?: return null
        val bytes = Base64.decode(encoded, Base64.NO_WRAP)
        require(bytes.size > 12) { "Cihaz anahtarı okunamadı; yeniden eşleştir." }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        return JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
    }

    @Synchronized fun saveCredentials(value: JSONObject) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.iv + cipher.doFinal(value.toString().toByteArray(Charsets.UTF_8))
        check(preferences.edit().putString("credentials", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit())
    }
    @Synchronized fun installCredentials(value: JSONObject) {
        // Encrypt first: a Keystore/storage failure must not erase the previous pair.
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.iv + cipher.doFinal(value.toString().toByteArray(Charsets.UTF_8))
        durable.clear()
        attachments.clear()
        synchronized(cacheLock) {
            check(preferences.edit().putString("credentials", Base64.encodeToString(encrypted, Base64.NO_WRAP))
                .putString("cacheIdentity", DurableLocalState.identity(value)).remove("sequence").remove("revoked").remove("lastSyncAt").putBoolean("background", false).commit())
            clearCache()
            lastSyncAt = null
        }
    }
    private fun clearCache() = synchronized(cacheLock) {
        synchronized(pendingLock) {
            cacheRevision++; pendingSnapshot = null; pendingResponses.clear(); pendingMessages.clear(); pendingResets.clear(); pendingChars = 0
            messagesRevision++
        }
        sequence = 0
        cache.delete()
        responses.clear(preferences.getString("cacheIdentity", null))
    }

    fun snapshot(): JSONObject = synchronized(cacheLock) {
        try {
            if (!preferences.contains("credentials") || !cache.exists() || cache.length() > MAX_SNAPSHOT_BYTES) emptySnapshot()
            else JSONObject(cache.readText()).let { snapshot ->
                val identity = preferences.getString("cacheIdentity", null)
                if (identity != null && identity != snapshot.optString("_deviceId")) emptySnapshot() else snapshot
            }
        } catch (_: Exception) { emptySnapshot() }
    }
    fun saveSnapshot(value: JSONObject) = synchronized(pendingLock) { lastSyncAt = java.time.Instant.now().toString(); pendingSnapshot = value; scheduleCache() }
    fun cachedResponse(path: String): JSONObject? {
        synchronized(pendingLock) {
            if (pendingResets.any { ResponseCache.isMessages(path, it) }) return null
        }
        return synchronized(cacheLock) { responses.get(path) }
    }
    fun cacheResponse(path: String, response: JSONObject) = synchronized(pendingLock) {
        val chars = response.toString().length
        if (chars > MAX_PENDING_CHARS) return@synchronized
        if (pendingResponses.size >= 16 || pendingChars + chars > MAX_PENDING_CHARS) { pendingResponses.clear(); pendingMessages.clear(); pendingChars = 0 }
        pendingResponses[path] = response; pendingChars += chars; scheduleCache()
    }
    fun resetMessages(sessionId: String? = null) = synchronized(pendingLock) {
        messagesRevision++
        pendingResponses.keys.filter { ResponseCache.isMessages(it, sessionId) }.forEach { pendingResponses.remove(it) }
        pendingMessages.keys.filter { sessionId == null || it.first == sessionId }.forEach { pendingMessages.remove(it) }
        if (sessionId == null) pendingResets.clear()
        if (null !in pendingResets) pendingResets.add(sessionId)
        if (pendingResets.size > 128) { pendingResets.clear(); pendingResets.add(null) }
        scheduleCache()
    }
    fun cacheMessage(sessionId: String, message: JSONObject) = synchronized(pendingLock) {
        if (sessionId.isBlank()) return@synchronized
        val chars = message.toString().length
        if (chars > MAX_PENDING_CHARS || pendingMessages.size >= 128 || pendingChars + chars > MAX_PENDING_CHARS) {
            pendingMessages.clear(); pendingResponses.clear()
            pendingResets.clear(); pendingResets.add(null); pendingChars = 0
        }
        if (chars <= MAX_PENDING_CHARS) { pendingMessages[sessionId to message.optString("id")] = message; pendingChars += chars }
        scheduleCache()
    }
    var background: Boolean
        get() = preferences.getBoolean("background", false)
        set(value) { check(preferences.edit().putBoolean("background", value).commit()) }
    var revoked: Boolean
        get() = preferences.getBoolean("revoked", false)
        set(value) { check(preferences.edit().putBoolean("revoked", value).commit()) }
    var theme: String
        get() = preferences.getString("theme", "system") ?: "system"
        set(value) { check(preferences.edit().putString("theme", value).commit()) }

    @Synchronized fun forget() {
        durable.clear()
        attachments.clear()
        check(preferences.edit().remove("credentials").remove("sequence").remove("revoked").remove("cacheIdentity").remove("lastSyncAt").putBoolean("background", false).commit())
        lastSyncAt = null
        clearCache()
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias(keyAlias)) store.deleteEntry(keyAlias)
    }

    companion object {
        private const val MAX_SNAPSHOT_BYTES = 8 * 1024 * 1024
        private const val MAX_PENDING_CHARS = 1024 * 1024
        fun emptySnapshot() = JSONObject().put("sequence", 0).put("serverName", "")
            .put("projects", JSONArray()).put("sessions", JSONArray())
            .put("interactions", JSONArray()).put("devices", JSONArray())
    }
}
