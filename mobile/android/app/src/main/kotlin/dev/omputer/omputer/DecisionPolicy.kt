package dev.omputer.omputer

import org.json.JSONObject
import java.time.Instant

internal object DecisionPolicy {
    fun finalSuccess(result: JSONObject): Boolean = result.optBoolean("success") &&
        result.optString("status") !in setOf("running", "unknown", "pending", "submitting") &&
        !(result.optBoolean("accepted") && !result.has("data") && result.optString("status") != "succeeded") && commandError(result) == null
    fun pending(request: JSONObject, now: Instant = Instant.now()): Boolean {
        if (request.optString("status") != "pending") return false
        val expiry = request.optString("expiresAt")
        if (expiry.isBlank() || expiry == "null") return true
        return try { Instant.parse(expiry).isAfter(now) } catch (_: Exception) { false }
    }
    fun commandError(result: JSONObject): Pair<String, String>? {
        result.optJSONObject("data")?.let { nested -> commandError(nested)?.let { return it } }
        if (result.opt("success") != false && result.opt("accepted") != false) return null
        val error = result.optJSONObject("error")
        val code = error?.optString("code")?.ifBlank { null } ?: result.optString("code").ifBlank { "command_rejected" }
        val message = error?.optString("message")?.ifBlank { null }
            ?: (result.opt("error") as? String)?.ifBlank { null }
            ?: result.optString("message").ifBlank { "PC komutu kabul etmedi. Kararı ve bağlantıyı kontrol et." }
        return code to message
    }
}
