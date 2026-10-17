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
    private val responseCache = File(context.filesDir, "responses").apply { mkdirs() }
    private val keyAlias = "omputer.device.v1"

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

    @Synchronized fun snapshot(): JSONObject = if (cache.exists()) JSONObject(cache.readText()) else emptySnapshot()
    @Synchronized fun saveSnapshot(value: JSONObject) {
        val temporary = File(cache.parentFile, "snapshot.tmp")
        temporary.writeText(value.toString())
        check(temporary.renameTo(cache)) { "Yerel proje hafızası kaydedilemedi." }
    }

    private fun responseFile(path: String): File {
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(path.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return File(responseCache, "$hash.json")
    }
    @Synchronized fun cachedResponse(path: String): JSONObject? {
        val file = responseFile(path)
        return if (file.exists()) JSONObject(file.readText()).getJSONObject("response") else null
    }
    @Synchronized fun cacheResponse(path: String, response: JSONObject) {
        val file = responseFile(path)
        val temporary = File(responseCache, "${file.name}.tmp")
        temporary.writeText(JSONObject().put("path", path).put("response", response).toString())
        check(temporary.renameTo(file)) { "Oturum önbelleği kaydedilemedi." }
        responseCache.listFiles()?.sortedByDescending { it.lastModified() }?.drop(80)?.forEach { check(it.delete()) }
    }
    @Synchronized fun resetMessages(sessionId: String) {
        responseCache.listFiles()?.filter { it.extension == "json" }?.forEach { file ->
            val entry = JSONObject(file.readText())
            if (entry.getString("path").startsWith("/v1/sessions/$sessionId/messages")) check(file.delete())
        }
    }
    @Synchronized fun cacheMessage(sessionId: String, message: JSONObject) {
        responseCache.listFiles()?.filter { it.extension == "json" }?.forEach { file ->
            val entry = JSONObject(file.readText())
            if (!entry.getString("path").startsWith("/v1/sessions/$sessionId/messages")) return@forEach
            val response = entry.getJSONObject("response")
            val rows = response.optJSONArray("messages") ?: return@forEach
            val next = JSONArray()
            var replaced = false
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                if (row.optString("id") == message.optString("id")) { next.put(message); replaced = true } else next.put(row)
            }
            if (replaced || !entry.getString("path").contains("before=")) {
                if (!replaced) next.put(message)
                val bounded = JSONArray()
                for (index in (next.length() - 500).coerceAtLeast(0) until next.length()) bounded.put(next.get(index))
                response.put("messages", bounded)
                cacheResponse(entry.getString("path"), response)
            }
        }
    }

    var sequence: Long
        get() = preferences.getLong("sequence", 0)
        set(value) { check(preferences.edit().putLong("sequence", value).commit()) }
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
        check(preferences.edit().remove("credentials").remove("sequence").remove("revoked").putBoolean("background", false).commit())
        if (cache.exists()) check(cache.delete())
        responseCache.listFiles()?.forEach { check(it.delete()) }
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias(keyAlias)) store.deleteEntry(keyAlias)
    }

    companion object {
        fun emptySnapshot() = JSONObject().put("sequence", 0).put("serverName", "")
            .put("projects", JSONArray()).put("sessions", JSONArray())
            .put("interactions", JSONArray()).put("devices", JSONArray())
    }
}
