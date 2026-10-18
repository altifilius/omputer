package dev.omputer.omputer

import org.json.JSONObject

internal object NotificationPreferences {
    fun enabled(preferences: JSONObject, session: String?, project: String?, kind: String): Boolean {
        val keys = listOfNotNull("global", project?.takeIf { it.isNotBlank() }?.let { "project:$it" },
            session?.takeIf { it.isNotBlank() }?.let { "session:$it" })
        return keys.all { key ->
            val value = preferences.opt(key)
            value != false && (value !is JSONObject || (value.opt("enabled") != false && value.opt(kind) != false &&
                (kind !in setOf("question", "approval") || value.opt("decisions") != false) &&
                (kind !in setOf("error", "completed", "activity") || value.opt("activity") != false)))
        }
    }
}
