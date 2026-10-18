package dev.omputer.omputer

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.util.UUID

class DurableLocalStateTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun operation(id: String = UUID.randomUUID().toString(), status: String = "unknown") = JSONObject()
        .put("id", id).put("status", status).put("request", JSONObject().put("id", id).put("action", "session.prompt")
            .put("payload", JSONObject().put("text", "Do not replay me")))

    @Test fun committedDraftsPreferencesAndUnknownCommandsSurviveRestartWithoutReplay() {
        val directory = temporary.newFolder()
        val first = DurableLocalState(directory)
        val operation = operation()
        first.set("pc-a:phone", "read", "session:s", JSONObject().put("messageId", "m"))
        first.saveDraft("pc-a:phone", "session:s:prompt", JSONObject().put("text", "durable text"))
        first.saveOperation("pc-a:phone", operation)
        val restarted = DurableLocalState(directory)
        assertEquals("durable text", restarted.draft("pc-a:phone", "session:s:prompt")!!.getString("text"))
        assertEquals("m", restarted.state("pc-a:phone").getJSONObject("sections").getJSONObject("read").getJSONObject("session:s").getString("messageId"))
        assertEquals("unknown", restarted.operations("pc-a:phone").getJSONObject(0).getString("status"))
        assertEquals("Do not replay me", restarted.operations("pc-a:phone").getJSONObject(0).getJSONObject("request").getJSONObject("payload").getString("text"))
    }
    @Test fun computerIdentityFencesDraftsAndCommandsAndClearRemovesAll() {
        val state = DurableLocalState(temporary.newFolder())
        state.saveDraft("pc-a:phone", "same", JSONObject().put("text", "secret"))
        state.saveOperation("pc-a:phone", operation())
        assertNull(state.draft("pc-b:phone", "same"))
        assertEquals(0, state.operations("pc-b:phone").length())
        state.clear()
        assertNull(state.draft("pc-a:phone", "same"))
        assertEquals(0, state.operations("pc-a:phone").length())
    }
    @Test fun allUnsentDraftReferencesSurviveRestartWithinOnlyTheirIdentity() {
        val directory = temporary.newFolder()
        val state = DurableLocalState(directory)
        state.saveDraft("first:phone", "session:a:prompt", JSONObject().put("attachments", org.json.JSONArray().put(JSONObject().put("id", "shared-image"))))
        state.saveDraft("first:phone", "session:b:follow-up", JSONObject().put("attachments", org.json.JSONArray().put(JSONObject().put("id", "shared-image"))))
        state.saveDraft("second:phone", "session:c:prompt", JSONObject().put("text", "Other computer"))
        state.deleteDraft("first:phone", "session:a:prompt")
        val drafts = DurableLocalState(directory).drafts("first:phone")
        assertFalse(drafts.has("session:a:prompt"))
        assertFalse(drafts.has("session:c:prompt"))
        assertEquals("shared-image", drafts.getJSONObject("session:b:follow-up").getJSONArray("attachments").getJSONObject(0).getString("id"))
        drafts.remove("session:b:follow-up")
        assertTrue(DurableLocalState(directory).drafts("first:phone").has("session:b:follow-up"))
    }
    @Test fun sameOperationCannotChangeRequestOrRegressFinalState() {
        val state = DurableLocalState(temporary.newFolder())
        val record = operation(status = "succeeded")
        state.saveOperation("a", record)
        val changed = JSONObject(record.toString())
        changed.getJSONObject("request").put("action", "session.abort")
        assertThrows(IllegalArgumentException::class.java) { state.saveOperation("a", changed) }
        record.put("status", "unknown")
        state.saveOperation("a", record)
        assertEquals("succeeded", state.operations("a").getJSONObject(0).getString("status"))
        state.removeOperation("a", record.getString("id"))
        assertEquals(0, state.operations("a").length())
    }
    @Test fun maximumAttachmentDraftAndExactCommandBothCommitWithoutDeletingDraft() {
        val state = DurableLocalState(temporary.newFolder())
        val encoded = "a".repeat(((AttachmentLimits.MAX_TOTAL + 2) / 3) * 4)
        val draft = JSONObject().put("text", "Send both images").put("data", encoded)
        state.saveDraft("a", "session:s:prompt", draft)
        val command = operation()
        command.getJSONObject("request").put("payload", draft)
        state.saveOperation("a", command)
        assertEquals(encoded.length, state.draft("a", "session:s:prompt")!!.getString("data").length)
        assertEquals(encoded.length, state.operations("a").getJSONObject(0).getJSONObject("request").getJSONObject("payload").getString("data").length)
    }
    @Test fun operationSummaryPreservesExactRequestAndNativeReplyCorrelation() {
        val state = DurableLocalState(temporary.newFolder())
        val record = operation().put("nativeReply", true)
        state.saveOperation("a", record)
        state.saveOperation("a", JSONObject().put("id", record.getString("id")).put("status", "running"))
        val stored = state.operations("a").getJSONObject(0)
        assertTrue(stored.getBoolean("nativeReply"))
        assertEquals("session.prompt", stored.getJSONObject("request").getString("action"))
        assertThrows(IllegalArgumentException::class.java) { state.saveOperation("a", operation().put("identity", "b")) }
    }
    @Test fun invalidAndOversizedWritesSurfaceAndPreservePriorData() {
        val state = DurableLocalState(temporary.newFolder())
        state.set("a", "pins", "s", true)
        assertThrows(IllegalArgumentException::class.java) { state.set("a", "pins", "s", "x".repeat(65537)) }
        assertTrue(state.state("a").getJSONObject("sections").getJSONObject("pins").getBoolean("s"))
        assertThrows(IllegalArgumentException::class.java) { state.set("a", "credentials", "token", "bad") }
        val inaccessible = File(temporary.newFolder(), "file").apply { writeText("not a directory") }
        assertThrows(IllegalStateException::class.java) { DurableLocalState(inaccessible).saveDraft("a", "key", JSONObject()) }
    }
    @Test fun corruptAuthoritativeStateIsNotSilentlyReplacedByEmptyState() {
        val directory = temporary.newFolder()
        val state = DurableLocalState(directory)
        state.saveDraft("a", "key", JSONObject().put("text", "saved"))
        directory.listFiles()!!.single().writeText("truncated")
        assertThrows(org.json.JSONException::class.java) { DurableLocalState(directory).draft("a", "key") }
    }
    @Test fun attachmentByteDimensionCountAndMimeLimitsAreExplicit() {
        assertArrayEquals(byteArrayOf(1, 2), AttachmentLimits.read(ByteArrayInputStream(byteArrayOf(1, 2))))
        assertThrows(IllegalArgumentException::class.java) { AttachmentLimits.read(ByteArrayInputStream(ByteArray(AttachmentLimits.MAX_BYTES + 1))) }
        assertThrows(IllegalArgumentException::class.java) { AttachmentLimits.read(ByteArrayInputStream(byteArrayOf())) }
        AttachmentLimits.validate(8, AttachmentLimits.MAX_TOTAL.toLong(), 100, 100, "image/png")
        assertThrows(IllegalArgumentException::class.java) { AttachmentLimits.validate(9, 10, 1, 1, "image/png") }
        assertThrows(IllegalArgumentException::class.java) { AttachmentLimits.validate(1, AttachmentLimits.MAX_TOTAL + 1L, 1, 1, "image/png") }
        assertThrows(IllegalArgumentException::class.java) { AttachmentLimits.validate(1, 1, 32768, 32768, "image/png") }
        assertThrows(IllegalArgumentException::class.java) { AttachmentLimits.validate(1, 1, 10, 10, "text/html") }
    }
    @Test fun acceptedRunningIsNotFinalAndScopedNotificationPreferencesAreEnforced() {
        assertFalse(DecisionPolicy.finalSuccess(JSONObject().put("success", true).put("accepted", true).put("status", "running")))
        assertTrue(DecisionPolicy.finalSuccess(JSONObject().put("success", true).put("status", "succeeded")))
        assertFalse(DecisionPolicy.finalSuccess(JSONObject().put("success", true).put("status", "succeeded")
            .put("data", JSONObject().put("accepted", false).put("error", "Not accepted"))))
        val prefs = JSONObject().put("project:p", false)
        assertFalse(NotificationPreferences.enabled(prefs, "s", "p", "question"))
        assertTrue(NotificationPreferences.enabled(prefs, "s", "other", "question"))
        prefs.put("session:s", JSONObject().put("decisions", false))
        assertFalse(NotificationPreferences.enabled(prefs, "s", "other", "approval"))
        assertTrue(NotificationPreferences.enabled(prefs, "s", "other", "error"))
        prefs.put("global", false)
        assertFalse(NotificationPreferences.enabled(prefs, null, null, "error"))
    }
}
