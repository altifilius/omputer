package dev.omputer.omputer

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID

internal object AttachmentLimits {
    const val MAX_BYTES = 1024 * 1024
    const val MAX_TOTAL = 2 * 1024 * 1024
    const val MAX_COUNT = 8
    fun read(input: InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size().toLong() + count <= MAX_BYTES) { "Görsel en fazla 1 MiB olabilir." }
            output.write(buffer, 0, count)
        }
        return output.toByteArray().also { require(it.isNotEmpty()) { "Görsel boş." } }
    }
    fun validate(count: Int, total: Long, width: Int, height: Int, mime: String) {
        require(count <= MAX_COUNT && total <= MAX_TOTAL) { "En fazla 8 görsel ve toplam 2 MiB eklenebilir." }
        require(width in 1..16384 && height in 1..16384 && width.toLong() * height <= 25_000_000L) { "Görsel boyutları desteklenmiyor." }
        require(mime in setOf("image/jpeg", "image/png", "image/webp", "image/gif")) { "JPEG, PNG, WebP veya GIF görseli seç." }
    }
}

internal class ImageAttachments(private val context: Context) {
    private val root = File(context.filesDir, "attachments")
    private fun directory(identity: String): File {
        val hash = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray()).joinToString("") { "%02x".format(it) }
        return File(root, hash)
    }
    private fun metadata(identity: String): JSONObject {
        val file = File(directory(identity), "index.json")
        return if (file.exists()) JSONObject(file.readText()) else JSONObject()
    }
    @Synchronized fun import(identity: String, uris: List<Uri>, shared: Boolean): List<Map<String, Any?>> {
        require(uris.size <= AttachmentLimits.MAX_COUNT) { "En fazla 8 görsel seç." }
        val directory = directory(identity)
        val index = metadata(identity)
        var total = index.keys().asSequence().sumOf { index.getJSONObject(it).getLong("bytes") }
        var count = index.length()
        val additions = mutableListOf<Pair<JSONObject, ByteArray>>()
        for (uri in uris) {
            require(uri.scheme == "content") { "Yalnızca sistem tarafından paylaşılan görseller destekleniyor." }
            val bytes = context.contentResolver.openInputStream(uri)?.use { AttachmentLimits.read(it) }
                ?: throw IllegalArgumentException("Görsel açılamadı.")
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            val mime = bounds.outMimeType ?: ""
            total += bytes.size; count++
            AttachmentLimits.validate(count, total, bounds.outWidth, bounds.outHeight, mime)
            val row = JSONObject().put("id", UUID.randomUUID().toString()).put("mimeType", mime)
                .put("width", bounds.outWidth).put("height", bounds.outHeight).put("bytes", bytes.size).put("shared", shared)
            additions.add(row to bytes)
        }
        try {
            additions.forEach { (row, bytes) ->
                DurableLocalState.atomicWrite(File(directory, row.getString("id")), bytes)
                index.put(row.getString("id"), row)
            }
            DurableLocalState.atomicWrite(File(directory, "index.json"), index.toString().toByteArray())
        } catch (error: Exception) {
            additions.forEach { (row, _) -> File(directory, row.getString("id")).delete() }
            throw error
        }
        return additions.map { (row, bytes) -> prepared(row, bytes) }
    }
    private fun prepared(row: JSONObject, bytes: ByteArray) = mapOf<String, Any?>("id" to row.getString("id"),
        "mimeType" to row.getString("mimeType"), "data" to Base64.encodeToString(bytes, Base64.NO_WRAP),
        "width" to row.getInt("width"), "height" to row.getInt("height"), "bytes" to bytes.size)
    @Synchronized fun shared(identity: String): List<Map<String, Any?>> {
        val index = metadata(identity)
        val rows = index.keys().asSequence().map { index.getJSONObject(it) }.filter { it.optBoolean("shared") }.toList()
        val result = rows.map { prepared(it, File(directory(identity), it.getString("id")).readBytes()) }
        rows.forEach { it.put("shared", false) }
        DurableLocalState.atomicWrite(File(directory(identity), "index.json"), index.toString().toByteArray())
        return result
    }
    @Synchronized fun remove(identity: String, id: String) {
        UUID.fromString(id)
        val index = metadata(identity); index.remove(id)
        DurableLocalState.atomicWrite(File(directory(identity), "index.json"), index.toString().toByteArray())
        check(!File(directory(identity), id).exists() || File(directory(identity), id).delete()) { "Görsel kaldırılamadı." }
    }
    @Synchronized fun clear() { check(!root.exists() || root.deleteRecursively()) { "Önceki ekler silinemedi." } }
}
