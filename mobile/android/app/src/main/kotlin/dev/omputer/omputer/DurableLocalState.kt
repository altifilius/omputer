package dev.omputer.omputer

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID

/** Authoritative user state: never shares the disposable HTTP cache's failure policy. */
internal class DurableLocalState(private val directory: File) {
    private fun file(identity: String): File {
        require(identity.isNotBlank()) { "Eşleştirme kimliği eksik." }
        val hash = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray()).joinToString("") { "%02x".format(it) }
        return File(directory, "$hash.json")
    }
    private fun read(identity: String): JSONObject {
        val file = file(identity)
        if (!file.exists()) return JSONObject().put("identity", identity).put("sections", JSONObject())
            .put("drafts", JSONObject()).put("operations", JSONObject())
        check(file.length() <= MAX_TOTAL_BYTES) { "Yerel durum boyutu geçersiz." }
        return JSONObject(file.readText()).also { check(it.getString("identity") == identity) { "Yerel durum kimliği uyuşmuyor." } }
    }
    private fun save(identity: String, state: JSONObject) {
        val bytes = state.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size <= MAX_TOTAL_BYTES) { "Yerel depolama dolu; eski taslak veya işlem kayıtlarını kaldır." }
        atomicWrite(file(identity), bytes)
    }
    @Synchronized fun state(identity: String): JSONObject {
        val state = read(identity)
        val sections = state.getJSONObject("sections")
        SECTIONS.forEach { if (!sections.has(it)) sections.put(it, JSONObject()) }
        return JSONObject().put("identity", identity).put("sections", sections)
    }
    @Synchronized fun set(identity: String, section: String, key: String, value: Any?): JSONObject {
        require(section in SECTIONS) { "Geçersiz yerel tercih bölümü." }; validateKey(key)
        validateSize(value, 64 * 1024)
        val state = read(identity)
        val sections = state.getJSONObject("sections")
        val values = sections.optJSONObject(section) ?: JSONObject().also { sections.put(section, it) }
        if (value == null || value == JSONObject.NULL) values.remove(key) else values.put(key, value)
        save(identity, state)
        return state(identity)
    }
    @Synchronized fun draft(identity: String, key: String): JSONObject? { validateKey(key); return read(identity).getJSONObject("drafts").optJSONObject(key) }
    @Synchronized fun drafts(identity: String): JSONObject = read(identity).getJSONObject("drafts")
    @Synchronized fun saveDraft(identity: String, key: String, value: JSONObject) {
        validateKey(key); validateSize(value, MAX_DRAFT_BYTES)
        val state = read(identity); state.getJSONObject("drafts").put(key, value); save(identity, state)
    }
    @Synchronized fun deleteDraft(identity: String, key: String) {
        validateKey(key); val state = read(identity); state.getJSONObject("drafts").remove(key); save(identity, state)
    }
    @Synchronized fun saveOperation(identity: String, value: JSONObject) {
        val id = value.getString("id"); UUID.fromString(id)
        validateSize(value, MAX_OPERATION_BYTES)
        val claimed = value.optString("identity")
        require(claimed.isBlank() || claimed == identity) { "İşlem farklı bilgisayara ait." }
        val state = read(identity); val operations = state.getJSONObject("operations")
        require(operations.has(id) || operations.length() < 1000) { "İşlem kayıtları dolu; sonuçlanan eski kayıtları kaldır." }
        val old = operations.optJSONObject(id)
        val request = value.optJSONObject("request")
        if (old?.optJSONObject("request") != null && request != null) {
            require(equivalent(old.getJSONObject("request"), request)) { "Aynı işlem kimliği farklı istekle kullanılamaz." }
        }
        if (old?.optString("status") in setOf("succeeded", "failed") && value.optString("status") !in setOf("succeeded", "failed")) return
        val copy = JSONObject()
        if (old != null) old.keys().forEach { copy.put(it, old.opt(it)) }
        value.keys().forEach { copy.put(it, value.opt(it)) }
        copy.put("identity", identity)
        if (request == null && old?.optJSONObject("request") != null) copy.put("request", old.getJSONObject("request"))
        operations.put(id, copy); save(identity, state)
    }
    @Synchronized fun operations(identity: String): JSONArray {
        val rows = read(identity).getJSONObject("operations")
        return JSONArray(rows.keys().asSequence().map { rows.getJSONObject(it) }.toList())
    }
    @Synchronized fun removeOperation(identity: String, id: String) {
        UUID.fromString(id); val state = read(identity); state.getJSONObject("operations").remove(id); save(identity, state)
    }
    @Synchronized fun clear() {
        if (!directory.exists()) return
        check(directory.deleteRecursively()) { "Önceki bilgisayarın yerel durumu silinemedi." }
    }
    companion object {
        const val MAX_DRAFT_BYTES = 6 * 1024 * 1024
        const val MAX_OPERATION_BYTES = 6 * 1024 * 1024
        const val MAX_TOTAL_BYTES = 10 * 1024 * 1024
        private val SECTIONS = setOf("pins", "read", "lastMode", "notificationPreferences")
        private fun validateKey(key: String) { require(key.isNotBlank() && key.length <= 512) { "Yerel kayıt anahtarı geçersiz." } }
        private fun validateSize(value: Any?, maximum: Int) { require((value?.toString() ?: "null").toByteArray().size <= maximum) { "Yerel kayıt çok büyük." } }
        private fun equivalent(a: Any?, b: Any?): Boolean = when {
            a is JSONObject && b is JSONObject -> a.keys().asSequence().toSet() == b.keys().asSequence().toSet() && a.keys().asSequence().all { equivalent(a.opt(it), b.opt(it)) }
            a is JSONArray && b is JSONArray -> a.length() == b.length() && (0 until a.length()).all { equivalent(a.opt(it), b.opt(it)) }
            else -> a == b
        }
        fun atomicWrite(file: File, bytes: ByteArray) {
            check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs()) { "Yerel dizin açılamadı." }
            val temporary = File(file.parentFile, ".${file.name}.${UUID.randomUUID()}.tmp")
            try {
                FileOutputStream(temporary).use { it.write(bytes); it.fd.sync() }
                check(temporary.renameTo(file)) { "Yerel kayıt atomik kaydedilemedi." }
            } finally { temporary.delete() }
        }
        fun identity(credentials: JSONObject): String = "${credentials.optString("serverId").ifBlank { credentials.getString("fingerprint") }}:${credentials.getString("deviceId")}"
    }
}
