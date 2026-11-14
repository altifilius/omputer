package dev.omputer.omputer

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AnswerPolicyTest {
    private fun session(count: Int = 3, revision: Int = 1, generation: String = "generation") = JSONObject()
        .put("id", "s").put("projectId", "p").put("name", "Session")
        .put("answerSummary", JSONObject().put("generation", generation).put("count", count)
            .put("latest", if (count == 0) JSONObject.NULL else JSONObject().put("messageId", "m$count")
                .put("revision", revision).put("sequence", count * 10).put("ordinal", count).put("preview", "Safe final answer")))

    @Test fun unopenedSessionHasThreeUnreadAnswersWithoutAnyTranscript() {
        val summary = AnswerPolicy.summary(session())!!
        assertEquals(3L, AnswerPolicy.unread(summary, "epoch", null))
        assertEquals("Safe final answer", summary.latest!!.preview)
    }

    private fun marker(ordinal: Int, revision: Int = 1, epoch: String = "epoch", generation: String = "generation") = JSONObject()
        .put("journalEpoch", epoch).put("generation", generation).put("ordinal", ordinal)
        .put("messageId", "m$ordinal").put("revision", revision).put("sequence", ordinal * 10)

    @Test fun partialReadAndLatestRevisionUseEpochAndGenerationNotTheTransportCursor() {
        val summary = AnswerPolicy.summary(session())!!
        assertEquals(2L, AnswerPolicy.unread(summary, "epoch", marker(1)))
        assertEquals(0L, AnswerPolicy.unread(summary, "epoch", marker(3)))
        assertEquals(1L, AnswerPolicy.unread(AnswerPolicy.summary(session(revision = 2))!!, "epoch", marker(3)))
        assertEquals(3L, AnswerPolicy.unread(summary, "restored", marker(3)))
        assertEquals(3L, AnswerPolicy.unread(AnswerPolicy.summary(session(generation = "branch"))!!, "epoch", marker(3)))
        assertEquals(3L, AnswerPolicy.unread(summary, "epoch", marker(3).also { it.remove("generation") }))
        assertEquals(3L, AnswerPolicy.unread(summary, "epoch", marker(4)))
    }

    @Test fun readAdmissionValidatesLatestAndCannotRegressAReadThroughMarker() {
        val summary = AnswerPolicy.summary(session())!!
        val latest = marker(3)
        val old = AnswerPolicy.marker(latest)!!
        assertEquals(old, AnswerPolicy.acceptRead(summary, "epoch", marker(1), latest))
        assertEquals(AnswerPolicy.marker(marker(2)), AnswerPolicy.acceptRead(summary, "epoch", marker(2), marker(1)))
        assertThrows(IllegalArgumentException::class.java) { AnswerPolicy.acceptRead(summary, "epoch", marker(3, 2), null) }
        assertThrows(IllegalArgumentException::class.java) { AnswerPolicy.acceptRead(summary, "epoch", marker(3).put("messageId", "wrong"), null) }
        assertThrows(IllegalArgumentException::class.java) { AnswerPolicy.acceptRead(summary, "epoch", marker(3).put("sequence", 99), null) }
        assertThrows(IllegalArgumentException::class.java) { AnswerPolicy.acceptRead(summary, "epoch", marker(4), null) }
        assertThrows(IllegalArgumentException::class.java) { AnswerPolicy.acceptRead(summary, "epoch", marker(0), null) }
        assertThrows(IllegalArgumentException::class.java) { AnswerPolicy.acceptRead(summary, "epoch", marker(1).put("revision", 1.5), null) }
        assertThrows(IllegalArgumentException::class.java) { AnswerPolicy.acceptRead(summary, "epoch", marker(1, epoch = "other"), null) }
        assertThrows(IllegalArgumentException::class.java) { AnswerPolicy.acceptRead(summary, "epoch", marker(1, generation = "branch"), null) }
        val revised = AnswerPolicy.summary(session(revision = 2))!!
        assertEquals(2L, AnswerPolicy.acceptRead(revised, "epoch", marker(3, 2), latest).revision)
        assertEquals(2L, AnswerPolicy.acceptRead(summary, "epoch", latest, marker(3, 2)).revision)
        assertEquals(AnswerPolicy.marker(marker(1)), AnswerPolicy.acceptRead(summary, "epoch", marker(1), marker(3, generation = "old")))
    }

    @Test fun deliveryDeduplicatesRestartAndDismissButSuppressionDoesNotConsumeUnread() {
        val summary = AnswerPolicy.summary(session())!!
        fun action(delivery: JSONObject? = null, visible: Boolean = false, active: Boolean = false,
            read: JSONObject? = null, enabled: Boolean = true, value: AnswerPolicy.Summary = summary) =
            AnswerPolicy.notificationAction(value, "epoch", read, delivery, visible, enabled, active)
        assertEquals(AnswerPolicy.NotificationAction.POST, action())
        assertEquals(AnswerPolicy.NotificationAction.NONE, action(delivery = marker(3)))
        assertEquals(AnswerPolicy.NotificationAction.UPDATE, action(delivery = marker(3), active = true, read = marker(1)))
        assertEquals(AnswerPolicy.NotificationAction.SUPPRESS, action(visible = true))
        assertEquals(AnswerPolicy.NotificationAction.POST, action(visible = false))
        assertEquals(AnswerPolicy.NotificationAction.POST, action(delivery = marker(3), value = AnswerPolicy.summary(session(revision = 2))!!))
        assertEquals(AnswerPolicy.NotificationAction.POST, action(delivery = marker(3, epoch = "old")))
        assertEquals(AnswerPolicy.NotificationAction.POST, action(delivery = marker(3), value = AnswerPolicy.summary(session(generation = "branch"))!!))
        assertEquals(AnswerPolicy.NotificationAction.CANCEL, action(read = marker(3)))
        assertEquals(AnswerPolicy.NotificationAction.CANCEL, action(enabled = false))
        assertEquals(3L, AnswerPolicy.unread(summary, "epoch", null))
    }

    @Test fun readerOwnersRequireNativeResumeAndExactSessionEpochAndGeneration() {
        val readers = AnswerReaders()
        readers.update("front", "s", "epoch", "generation", true)
        assertFalse(readers.visible("s", "epoch", "generation"))
        readers.activityResumed(true)
        assertFalse(readers.visible("s", "epoch", "generation"))
        readers.update("front", "s", "epoch", "generation", true)
        readers.update("other", "sibling", "epoch", "generation", true)
        assertTrue(readers.visible("s", "epoch", "generation"))
        assertFalse(readers.visible("s", "restored", "generation"))
        assertFalse(readers.visible("s", "epoch", "branch"))
        readers.update("front", "s", "epoch", "generation", false)
        assertFalse(readers.visible("s", "epoch", "generation"))
        assertTrue(readers.visible("sibling", "epoch", "generation"))
        readers.update("other", null, null, null, true)
        assertFalse(readers.visible("sibling", "epoch", "generation"))
        readers.update("front", "s", "epoch", "generation", true)
        readers.activityResumed(false)
        readers.update("late", "s", "epoch", "generation", true)
        assertFalse(readers.visible("s", "epoch", "generation"))
        readers.activityResumed(true)
        assertFalse(readers.visible("s", "epoch", "generation"))
        readers.update("front", "s", "epoch", "generation", true)
        readers.clear()
        assertFalse(readers.visible("s", "epoch", "generation"))
    }

    @Test fun authoritativeSummaryReplacesGenericTurnDoneButOldPcKeepsLegacyFallback() {
        assertFalse(AnswerPolicy.legacyNotificationAllowed(session(), "turn_done"))
        assertFalse(AnswerPolicy.legacyNotificationAllowed(session(count = 0), "turn_done"))
        assertTrue(AnswerPolicy.legacyNotificationAllowed(JSONObject().put("id", "s"), "turn_done"))
        assertTrue(AnswerPolicy.legacyNotificationAllowed(session(), "error"))
        assertTrue(AnswerPolicy.legacyNotificationAllowed(session(), "question"))
    }

    @Test fun staleCachedSummaryCannotResurrectDismissedAnswersOrCancelANewerNotification() {
        val summary = AnswerPolicy.summary(session())!!
        val read = marker(3)
        for (delivered in listOf(marker(4), marker(3, 2))) {
            assertEquals(AnswerPolicy.NotificationAction.NONE,
                AnswerPolicy.notificationAction(summary, "epoch", null, delivered, false, true, false))
            assertEquals(AnswerPolicy.NotificationAction.NONE,
                AnswerPolicy.notificationAction(summary, "epoch", read, delivered, false, true, true))
        }
    }

    @Test fun turnDoneRespectsActivityPreferenceWithoutMutingDecisions() {
        val preferences = JSONObject().put("session:s", JSONObject().put("activity", false))
        assertFalse(NotificationPreferences.enabled(preferences, "s", "p", "turn_done"))
        assertFalse(NotificationPreferences.enabled(preferences, "s", "p", "completed"))
        assertFalse(NotificationPreferences.enabled(preferences, "s", "p", "error"))
        assertTrue(NotificationPreferences.enabled(preferences, "s", "p", "question"))
        assertTrue(NotificationPreferences.enabled(preferences, "s", "p", "approval"))
    }

    @Test fun preferenceChangeCancelsOnlyDisabledNotificationsAndKeepsDeliveredAnswersActive() {
        data class Active(val session: String?, val project: String?, val kind: String)
        val answer = Active("s", "p", "turn_done")
        val question = Active("s", "p", "question")
        val sibling = Active("sibling", "other", "turn_done")
        val error = Active("muted", "muted-project", "error")
        val projectError = Active(null, "muted-project", "error")
        val approval = Active("muted", "muted-project", "approval")
        val active = listOf(answer, question, sibling, error, projectError, approval)
        val preferences = JSONObject().put("project:muted-project", JSONObject().put("activity", false))
        fun disabled(value: JSONObject) = NotificationPreferences.disabled(active) {
            NotificationPreferences.enabled(value, it.session, it.project, it.kind)
        }
        val cancelled = disabled(preferences)
        assertEquals(listOf(error, projectError), cancelled)
        assertEquals(AnswerPolicy.NotificationAction.UPDATE, AnswerPolicy.notificationAction(
            AnswerPolicy.summary(session())!!, "epoch", null, marker(3), false, true, answer !in cancelled))
        assertEquals(active, disabled(JSONObject().put("global", false)))
        assertEquals(emptyList<Active>(), disabled(JSONObject()))
    }

    @Test fun sourceRevisionNeverChangesSemanticReadOrNotificationDelivery() {
        val original = AnswerPolicy.summary(session())!!
        val updated = session().also {
            it.getJSONObject("answerSummary").getJSONObject("latest").put("sourceRevision", 99)
        }
        val summary = AnswerPolicy.summary(updated)!!
        val read = marker(3).put("sourceRevision", 1)
        val delivered = marker(3).put("sourceRevision", 50)
        assertEquals(original, summary)
        assertEquals(0L, AnswerPolicy.unread(summary, "epoch", read))
        assertEquals(AnswerPolicy.marker(marker(3)), AnswerPolicy.acceptRead(summary, "epoch", read, null))
        assertEquals(AnswerPolicy.NotificationAction.NONE,
            AnswerPolicy.notificationAction(summary, "epoch", null, delivered, false, true, false))
    }
}
