package dev.omputer.omputer

import org.json.JSONObject

/** Epoch changes are accepted only at an authenticated snapshot boundary. */
internal object JournalEpoch {
    fun value(snapshot: JSONObject): String? = snapshot.optString("journalEpoch").takeIf { it.isNotBlank() && it != "null" }

    fun changes(current: JSONObject, incoming: JSONObject): Boolean = value(incoming)?.let { it != value(current) } == true

    fun accepts(current: JSONObject, incoming: JSONObject, authenticatedSnapshot: Boolean, retired: Set<String>): Boolean {
        val incomingEpoch = value(incoming)
        if (incomingEpoch != null && incomingEpoch in retired) return false
        if (changes(current, incoming)) return authenticatedSnapshot
        if (value(current) != null && incomingEpoch == null) return false
        return incoming.optLong("sequence") >= current.optLong("sequence")
    }
}
