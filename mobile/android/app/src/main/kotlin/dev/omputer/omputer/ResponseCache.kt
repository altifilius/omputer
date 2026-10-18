package dev.omputer.omputer

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/** Disposable offline pages, not authoritative history. Index once, never scan JSON per token. */
internal class ResponseCache(private val directory: File, private val maxBytes: Long = 24L * 1024 * 1024,
    private val maxEntries: Int = 80, private val maxEntryBytes: Long = 2L * 1024 * 1024,
    private var identity: String? = null) {
    private val entries = linkedMapOf<String, File>()
    init {
        directory.mkdirs()
        var bytes = 0L
        val files = directory.listFiles().orEmpty().sortedByDescending { it.lastModified() }
        for (file in files) {
            if (file.extension != "json" || file.length() > maxEntryBytes || entries.size >= maxEntries || bytes + file.length() > maxBytes) {
                file.delete(); continue
            }
            try {
                val entry = JSONObject(file.readText())
                if (identity != null && entry.optString("_identity") != identity) { file.delete(); continue }
                entries[entry.getString("path")] = file
                bytes += file.length()
            } catch (_: Exception) { file.delete() }
        }
        val oldestFirst = entries.toList().asReversed()
        entries.clear(); oldestFirst.forEach { (path, file) -> entries[path] = file }
    }
    @Synchronized fun get(path: String): JSONObject? {
        val file = entries[path] ?: return null
        return try {
            if (file.length() > maxEntryBytes) { remove(path); null }
            else JSONObject(file.readText()).getJSONObject("response")
        } catch (_: Exception) { remove(path); null }
    }
    @Synchronized fun put(path: String, response: JSONObject) {
        val raw = JSONObject().put("path", path).put("response", response).put("_identity", identity).toString()
        if (raw.length > maxEntryBytes || raw.toByteArray(Charsets.UTF_8).size > maxEntryBytes) { remove(path); return }
        val name = MessageDigest.getInstance("SHA-256").digest(path.toByteArray()).joinToString("") { "%02x".format(it) }
        val file = File(directory, "$name.json")
        val temporary = File(directory, "$name.tmp")
        temporary.writeText(raw)
        check(temporary.renameTo(file)) { "Oturum önbelleği kaydedilemedi." }
        entries.remove(path); entries[path] = file
        var bytes = entries.values.sumOf { it.length() }
        while (entries.size > maxEntries || bytes > maxBytes) {
            val oldest = entries.entries.first()
            bytes -= oldest.value.length(); remove(oldest.key)
        }
    }
    @Synchronized fun resetMessages(sessionId: String? = null) {
        entries.keys.filter { isMessages(it, sessionId) }.forEach(::remove)
    }
    @Synchronized fun updateMessage(sessionId: String, message: JSONObject) {
        if (sessionId.isBlank() || message.optString("id").isBlank()) return
        for (path in entries.keys.filter { isMessages(it, sessionId) }) {
            val response = get(path) ?: continue
            val rows = response.optJSONArray("messages") ?: continue
            val next = JSONArray()
            var replaced = false
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                if (row.optString("id") == message.optString("id")) {
                    // A late HTTP/live frame cannot replace a newer cached revision.
                    next.put(if (row.optLong("revision") > message.optLong("revision")) row else message)
                    replaced = true
                } else next.put(row)
            }
            if (!replaced && path.contains("before=")) continue
            if (!replaced) next.put(message)
            val bounded = JSONArray()
            for (index in (next.length() - 500).coerceAtLeast(0) until next.length()) bounded.put(next.get(index))
            response.put("messages", bounded)
            put(path, response)
        }
    }
    @Synchronized fun clear(nextIdentity: String? = identity) {
        entries.keys.toList().forEach(::remove)
        directory.listFiles().orEmpty().forEach { it.delete() }
        identity = nextIdentity
    }
    private fun remove(path: String) { entries.remove(path)?.delete() }
    companion object {
        fun isMessages(path: String, sessionId: String? = null): Boolean {
            val route = path.substringBefore('?')
            return if (sessionId == null) route.startsWith("/v1/sessions/") && route.endsWith("/messages")
            else route == "/v1/sessions/$sessionId/messages"
        }
    }
}
