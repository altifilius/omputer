package dev.omputer.omputer

import org.json.JSONObject

/** The PC's bounded completed-answer index, never a transcript-derived guess. */
internal object AnswerPolicy {
    data class Reference(val messageId: String, val revision: Long, val sequence: Long,
        val ordinal: Long, val preview: String, val timestamp: String? = null)
    data class Summary(val generation: String, val count: Long, val latest: Reference?)

    fun summary(session: JSONObject): Summary? {
        val value = session.optJSONObject("answerSummary") ?: return null
        val generation = value.opt("generation") as? String ?: return null
        val count = integer(value.opt("count")) ?: return null
        if (generation.isBlank() || generation.length > 512 || count < 0) return null
        if (count == 0L) return if (value.isNull("latest")) Summary(generation, count, null) else null
        val latest = value.optJSONObject("latest") ?: return null
        val id = latest.opt("messageId") as? String ?: return null
        val revision = integer(latest.opt("revision")) ?: return null
        val sequence = integer(latest.opt("sequence")) ?: return null
        val ordinal = integer(latest.opt("ordinal")) ?: return null
        val preview = latest.opt("preview") as? String ?: return null
        if (id.isBlank() || id.length > 512 || revision < 1 || sequence < 0 || ordinal != count) return null
        return Summary(generation, count, Reference(id, revision, sequence, ordinal, preview,
            (latest.opt("timestamp") as? String)?.takeIf { it.isNotBlank() }))
    }

    fun unread(summary: Summary, epoch: String, marker: JSONObject?): Long {
        val read = marker(marker)
        if (read == null || read.journalEpoch != epoch || read.generation != summary.generation ||
            read.ordinal > summary.count) return summary.count
        if (read.ordinal < summary.count) return summary.count - read.ordinal
        val latest = summary.latest ?: return 0
        return if (read.messageId == latest.messageId && read.sequence == latest.sequence &&
            read.revision == latest.revision) 0 else 1
    }

    data class Marker(val journalEpoch: String, val generation: String, val ordinal: Long,
        val messageId: String, val revision: Long, val sequence: Long) {
        fun json(): JSONObject = JSONObject().put("journalEpoch", journalEpoch).put("generation", generation)
            .put("ordinal", ordinal).put("messageId", messageId).put("revision", revision).put("sequence", sequence)
    }

    fun marker(value: JSONObject?): Marker? {
        if (value == null) return null
        val epoch = value.opt("journalEpoch") as? String ?: return null
        val generation = value.opt("generation") as? String ?: return null
        val id = value.opt("messageId") as? String ?: return null
        val ordinal = integer(value.opt("ordinal")) ?: return null
        val revision = integer(value.opt("revision")) ?: return null
        val sequence = integer(value.opt("sequence")) ?: return null
        if (listOf(epoch, generation, id).any { it.isBlank() || it.length > 512 } ||
            ordinal < 1 || revision < 1 || sequence < 0) return null
        return Marker(epoch, generation, ordinal, id, revision, sequence)
    }

    fun acceptRead(summary: Summary, epoch: String, incoming: JSONObject, previous: JSONObject?): Marker {
        val candidate = requireNotNull(marker(incoming)) { "Yanıt okuma konumu geçersiz." }
        require(candidate.journalEpoch == epoch && candidate.generation == summary.generation) { "Yanıt geçmişi değişti." }
        require(candidate.ordinal <= summary.count && candidate.sequence <= (summary.latest?.sequence ?: -1)) { "Yanıt okuma konumu aralık dışında." }
        if (candidate.ordinal == summary.count) {
            val latest = requireNotNull(summary.latest)
            require(candidate.messageId == latest.messageId && candidate.revision == latest.revision &&
                candidate.sequence == latest.sequence) { "Son yanıt değişti; güncel yanıtı yeniden aç." }
        }
        val old = marker(previous)?.takeIf { it.journalEpoch == epoch && it.generation == summary.generation && it.ordinal <= summary.count }
        if (old != null) {
            if (old.ordinal > candidate.ordinal) return old
            if (old.ordinal == candidate.ordinal) {
                require(old.messageId == candidate.messageId && old.sequence == candidate.sequence) { "Yanıt kimliği değişti." }
                if (old.revision >= candidate.revision) return old
            }
        }
        return candidate
    }

    enum class NotificationAction { POST, UPDATE, CANCEL, SUPPRESS, NONE }

    fun notificationAction(summary: Summary, epoch: String, read: JSONObject?, delivery: JSONObject?,
        visible: Boolean, enabled: Boolean, active: Boolean): NotificationAction {
        if (!enabled) return NotificationAction.CANCEL
        val latest = summary.latest
        val delivered = marker(delivery)
        if (delivered != null && delivered.journalEpoch == epoch && delivered.generation == summary.generation &&
            (delivered.ordinal > summary.count || (latest != null && delivered.ordinal == summary.count &&
                delivered.messageId == latest.messageId && delivered.sequence == latest.sequence && delivered.revision > latest.revision)))
            return NotificationAction.NONE
        if (unread(summary, epoch, read) == 0L) return NotificationAction.CANCEL
        if (visible) return NotificationAction.SUPPRESS
        if (latest == null) return NotificationAction.CANCEL
        val same = delivered == Marker(epoch, summary.generation, latest.ordinal, latest.messageId, latest.revision, latest.sequence)
        return if (same) {
            if (active) NotificationAction.UPDATE else NotificationAction.NONE
        } else NotificationAction.POST
    }

    fun latestMarker(summary: Summary, epoch: String): Marker? = summary.latest?.let {
        Marker(epoch, summary.generation, it.ordinal, it.messageId, it.revision, it.sequence)
    }

    fun legacyNotificationAllowed(session: JSONObject?, kind: String): Boolean =
        kind != "turn_done" || session == null || summary(session) == null

    private fun integer(value: Any?): Long? = when (value) {
        is Int -> value.toLong()
        is Long -> value
        else -> null
    }
}
