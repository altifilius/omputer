package dev.omputer.omputer

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.time.Instant
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
        return JSONObject(file.readText()).also { state ->
            check(state.getString("identity") == identity) { "Yerel durum kimliği uyuşmuyor." }
            val operations = state.getJSONObject("operations")
            operations.keys().forEach { normalizeOutcomeUnknown(operations.getJSONObject(it)) }
        }
    }
    private fun save(identity: String, state: JSONObject, preservedOperationId: String? = null) {
        val operations = state.getJSONObject("operations")
        var bytes = state.toString().toByteArray(Charsets.UTF_8)
        var totalBytes = bytes.size.toLong()
        if (operations.length() > MAX_OPERATIONS || totalBytes > MAX_TOTAL_BYTES) {
            val candidates = operations.keys().asSequence()
                .filter { it != preservedOperationId && canRetire(operations.getJSONObject(it)) }
                .map { id -> id to runCatching { Instant.parse(operations.getJSONObject(id).optString("createdAt")) }.getOrDefault(Instant.EPOCH) }
                .sortedWith(compareBy<Pair<String, Instant>> { it.second }.thenBy { it.first })
                .toList()
            for ((id, _) in candidates) {
                if (operations.length() <= MAX_OPERATIONS && totalBytes <= MAX_TOTAL_BYTES) break
                // Each removed object entry contributes its key, colon, value, and (unless
                // it was the only entry) one comma. Do not reserialize the whole state per victim.
                totalBytes -= JSONObject.quote(id).toByteArray(Charsets.UTF_8).size.toLong() + 1 +
                    operations.getJSONObject(id).toString().toByteArray(Charsets.UTF_8).size +
                    if (operations.length() > 1) 1 else 0
                operations.remove(id)
            }
            require(operations.length() <= MAX_OPERATIONS && totalBytes <= MAX_TOTAL_BYTES) {
                "Yerel depolama dolu; bekleyen işlemler ve kaydedilmemiş taslaklar korunuyor."
            }
            bytes = state.toString().toByteArray(Charsets.UTF_8)
        }
        require(bytes.size <= MAX_TOTAL_BYTES) { "Yerel depolama dolu; bekleyen işlemler ve kaydedilmemiş taslaklar korunuyor." }
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
    @Synchronized fun commitAnswerRead(identity: String, key: String, summary: AnswerPolicy.Summary,
        epoch: String, incoming: JSONObject): JSONObject {
        validateKey(key)
        val state = read(identity)
        val sections = state.getJSONObject("sections")
        val values = sections.optJSONObject("read") ?: JSONObject().also { sections.put("read", it) }
        val accepted = AnswerPolicy.acceptRead(summary, epoch, incoming, values.optJSONObject(key))
        values.put(key, accepted.json())
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
        val old = operations.optJSONObject(id)
        val request = value.optJSONObject("request")
        if (old?.optJSONObject("request") != null && request != null) {
            require(equivalent(old.getJSONObject("request"), request)) { "Aynı işlem kimliği farklı istekle kullanılamaz." }
        }
        val uncertainFailure = isOutcomeUnknownFailure(value)
        val incomingStatus = if (uncertainFailure) "unknown" else value.optString("status")
        if (old?.optString("status") in FINAL_STATUSES && incomingStatus !in FINAL_STATUSES) return
        val copy = JSONObject()
        if (old != null) old.keys().forEach { copy.put(it, old.opt(it)) }
        value.keys().forEach { copy.put(it, value.opt(it)) }
        if (uncertainFailure) {
            copy.put("result", JSONObject(value.getJSONObject("result").toString()))
            normalizeOutcomeUnknown(copy)
        }
        copy.put("identity", identity)
        if (request == null && old?.optJSONObject("request") != null) copy.put("request", old.getJSONObject("request"))
        validateSize(copy, MAX_OPERATION_BYTES)
        operations.put(id, copy); save(identity, state, preservedOperationId = id)
    }
    @Synchronized fun operations(identity: String): JSONArray {
        val rows = read(identity).getJSONObject("operations")
        return JSONArray(rows.keys().asSequence().map { rows.getJSONObject(it) }.toList())
    }
    @Synchronized fun removeOperation(identity: String, id: String) {
        UUID.fromString(id)
        val state = read(identity)
        val operations = state.getJSONObject("operations")
        val record = operations.optJSONObject(id) ?: return
        require(canRetire(record)) { "Bekleyen veya taslak etkisi uygulanmamış işlem kaldırılamaz." }
        operations.remove(id)
        save(identity, state)
    }
    @Synchronized fun clear() {
        if (!directory.exists()) return
        check(directory.deleteRecursively()) { "Önceki bilgisayarın yerel durumu silinemedi." }
    }
    companion object {
        const val MAX_DRAFT_BYTES = 6 * 1024 * 1024
        const val MAX_OPERATION_BYTES = 6 * 1024 * 1024
        const val MAX_TOTAL_BYTES = 10 * 1024 * 1024
        private const val MAX_OPERATIONS = 1000
        private val FINAL_STATUSES = setOf("succeeded", "failed")
        private fun isOutcomeUnknownFailure(record: JSONObject): Boolean = record.optString("status") == "failed" &&
            record.optJSONObject("result")?.optJSONObject("error")?.optString("code") == "outcome_unknown"
        private fun normalizeOutcomeUnknown(record: JSONObject) {
            if (isOutcomeUnknownFailure(record)) {
                record.put("status", "unknown")
                record.getJSONObject("result").put("status", "unknown")
            }
        }
        private fun canRetire(record: JSONObject): Boolean {
            if (record.optString("status") !in FINAL_STATUSES || record.optString("draftEffect") == "review") return false
            val unappliedDraft = record.optString("draftEffect").isBlank() || record.isNull("draftEffect")
            return record.optString("status") != "succeeded" || !unappliedDraft ||
                (record.isNull("draftSubmission") && record.isNull("branchRestore"))
        }
        // notificationDelivery is native-owned: delivered answer refs, never user read state.
        private val SECTIONS = setOf("pins", "read", "lastMode", "notificationPreferences", "notificationDelivery")
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
