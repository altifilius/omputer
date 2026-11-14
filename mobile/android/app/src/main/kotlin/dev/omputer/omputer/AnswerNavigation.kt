package dev.omputer.omputer

import org.json.JSONObject

/** Native-only notification target; its scope must never become channel data. */
internal class AnswerNavigation {
    class Target private constructor(val sessionId: String, val identity: String,
        val journalEpoch: String, val generation: String) {
        companion object {
            fun create(sessionId: String?, identity: String?, journalEpoch: String?, generation: String?): Target? {
                if (listOf(sessionId, journalEpoch, generation).any { it.isNullOrBlank() || it.length > 512 } ||
                    identity.isNullOrBlank() || identity.length > 2048) return null
                return Target(sessionId!!, identity, journalEpoch!!, generation!!)
            }
        }
    }
    class Ticket internal constructor(internal val target: Target)
    private var identity: String? = null
    private var current = JSONObject()
    private var fresh = false
    private var pending: Ticket? = null

    fun resetIdentity(value: String?) { identity = value; current = JSONObject(); fresh = false; clear() }
    fun clear() { pending = null }
    fun snapshot(value: JSONObject, authenticated: Boolean) {
        current = value
        if (authenticated) fresh = true
        if (fresh && pending?.let { !matches(it.target) } == true) clear()
    }
    fun request(target: Target): Boolean {
        if (identity != target.identity || (fresh && !matches(target))) return false
        pending = Ticket(target)
        return true
    }
    fun pendingTicket(): Ticket? = pending?.takeIf { fresh && matches(it.target) }
    fun deliver(ticket: Ticket, send: (Map<String, Any?>) -> Unit): Boolean {
        if (pending !== ticket || !fresh || !matches(ticket.target)) return false
        pending = null
        send(mapOf("sessionId" to ticket.target.sessionId, "answer" to true))
        return true
    }
    private fun matches(target: Target): Boolean {
        if (identity != target.identity || JournalEpoch.value(current) != target.journalEpoch) return false
        val sessions = current.optJSONArray("sessions") ?: return false
        return (0 until sessions.length()).asSequence().mapNotNull { sessions.optJSONObject(it) }
            .firstOrNull { it.optString("id") == target.sessionId }?.let(AnswerPolicy::summary)?.generation == target.generation
    }
}
