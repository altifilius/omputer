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


    private fun seed(directory: File, records: List<JSONObject>, draft: JSONObject = JSONObject().put("text", "Unsent draft")): File {
        DurableLocalState(directory).saveDraft("a", "session:s:prompt", draft)
        val file = directory.listFiles()!!.single()
        val state = JSONObject(file.readText())
        val operations = state.getJSONObject("operations")
        records.forEach { operations.put(it.getString("id"), it) }
        file.writeText(state.toString())
        assertTrue(file.length() <= DurableLocalState.MAX_TOTAL_BYTES)
        return file
    }

    private fun records(state: DurableLocalState): Map<String, JSONObject> {
        val rows = state.operations("a")
        return (0 until rows.length()).associate { rows.getJSONObject(it).let { row -> row.getString("id") to row } }
    }

    @Test fun thousandAndFirstCommandRetiresOldestSafeFinalAndKeepsProtectedRequestsAndDrafts() {
        val directory = temporary.newFolder()
        val protected = listOf(
            operation().put("createdAt", "2000-01-01T00:00:00Z"),
            operation(status = "running").put("createdAt", "2000-01-01T00:00:00Z"),
            operation(status = "succeeded").put("draftSubmission", JSONObject().put("key", "session:s:prompt")),
            operation(status = "succeeded").put("branchRestore", JSONObject().put("key", "session:s:prompt")).put("draftEffect", JSONObject.NULL),
            operation(status = "succeeded").put("branchRestore", JSONObject().put("key", "session:s:prompt")).put("draftEffect", "review")
        )
        val oldest = operation(status = "failed").put("createdAt", "2001-01-01T00:00:00Z")
        val finals = (1..994).map { operation(status = "succeeded").put("createdAt", "2026-01-01T00:00:00Z") }
        val file = seed(directory, protected + oldest + finals)
        val incoming = operation(status = "succeeded").put("createdAt", "1990-01-01T00:00:00Z")
        DurableLocalState(directory).saveOperation("a", incoming)
        val restarted = DurableLocalState(directory)
        val persisted = records(restarted)
        assertEquals(1000, persisted.size)
        assertFalse(persisted.containsKey(oldest.getString("id")))
        assertTrue(persisted.containsKey(incoming.getString("id")))
        protected.forEach { expected ->
            val actual = persisted.getValue(expected.getString("id"))
            assertEquals(expected.toString(), actual.toString())
            assertEquals(expected.getJSONObject("request").toString(), actual.getJSONObject("request").toString())
        }
        assertEquals("Unsent draft", restarted.draft("a", "session:s:prompt")!!.getString("text"))
        assertTrue(file.length() <= DurableLocalState.MAX_TOTAL_BYTES)
    }

    @Test fun equalAgeFinalsRetireByUuidInsteadOfJsonIterationOrder() {
        val directory = temporary.newFolder()
        val finals = (1..1000).reversed().map {
            operation(UUID(0, it.toLong()).toString(), "failed").put("createdAt", "2026-01-01T00:00:00Z")
        }
        seed(directory, finals)
        val incoming = operation()
        DurableLocalState(directory).saveOperation("a", incoming)
        val persisted = records(DurableLocalState(directory))
        assertEquals(1000, persisted.size)
        assertFalse(persisted.containsKey(UUID(0, 1).toString()))
        assertTrue(persisted.containsKey(UUID(0, 2).toString()))
        assertTrue(persisted.containsKey(incoming.getString("id")))
    }

    @Test fun aggregateBytePressureRetiresSeveralFinalsWithoutTouchingProtectedData() {
        val directory = temporary.newFolder()
        val oldest = operation(status = "failed").put("createdAt", "2020-01-01T00:00:00Z").put("result", "x".repeat(2 * 1024 * 1024))
        val next = operation(status = "succeeded").put("createdAt", "2021-01-01T00:00:00Z").put("result", "x".repeat(2 * 1024 * 1024))
        val protected = operation(status = "running").put("result", "x".repeat(2 * 1024 * 1024))
        val draft = JSONObject().put("text", "ç".repeat(1024 * 1024))
        val file = seed(directory, listOf(oldest, next, protected), draft)
        val incoming = operation().put("result", "y".repeat(5 * 1024 * 1024))
        DurableLocalState(directory).saveOperation("a", incoming)
        val restarted = DurableLocalState(directory)
        val persisted = records(restarted)
        assertEquals(setOf(protected.getString("id"), incoming.getString("id")), persisted.keys)
        assertEquals(protected.toString(), persisted.getValue(protected.getString("id")).toString())
        assertEquals(draft.toString(), restarted.draft("a", "session:s:prompt")!!.toString())
        assertTrue(file.length() <= DurableLocalState.MAX_TOTAL_BYTES)
    }

    @Test fun draftAndPreferenceSavesAlsoRetireSafeFinalHistoryUnderBytePressure() {
        for (preference in listOf(false, true)) {
            val directory = temporary.newFolder()
            val final = operation(status = "failed").put("result", "f".repeat(1024 * 1024))
            val protected = operation().put("result", "p".repeat(4 * 1024 * 1024))
            val draft = JSONObject().put("text", "d".repeat(5 * 1024 * 1024 - 4096))
            val file = seed(directory, listOf(final, protected), draft)
            val state = DurableLocalState(directory)
            if (preference) state.set("a", "notificationPreferences", "session:s", "p".repeat(32 * 1024))
            else state.saveDraft("a", "session:new:prompt", JSONObject().put("text", "n".repeat(32 * 1024)))
            val restarted = DurableLocalState(directory)
            assertEquals(setOf(protected.getString("id")), records(restarted).keys)
            assertEquals(draft.toString(), restarted.draft("a", "session:s:prompt")!!.toString())
            if (preference) assertEquals(32 * 1024, restarted.state("a").getJSONObject("sections").getJSONObject("notificationPreferences").getString("session:s").length)
            else assertEquals(32 * 1024, restarted.draft("a", "session:new:prompt")!!.getString("text").length)
            assertTrue(file.length() <= DurableLocalState.MAX_TOTAL_BYTES)
        }
    }

    @Test fun protectedCountAndByteOverflowFailWithoutChangingOriginalFile() {
        val countDirectory = temporary.newFolder()
        val countFile = seed(countDirectory, (1..1000).map { operation() })
        val countBefore = countFile.readBytes()
        assertThrows(IllegalArgumentException::class.java) { DurableLocalState(countDirectory).saveOperation("a", operation()) }
        assertArrayEquals(countBefore, countFile.readBytes())
        assertEquals(1000, records(DurableLocalState(countDirectory)).size)

        val byteDirectory = temporary.newFolder()
        val protected = operation(status = "running").put("result", "p".repeat(5 * 1024 * 1024))
        val final = operation(status = "failed").put("result", "f".repeat(512 * 1024))
        val byteFile = seed(byteDirectory, listOf(protected, final), JSONObject().put("text", "d".repeat(4 * 1024 * 1024)))
        val byteBefore = byteFile.readBytes()
        assertThrows(IllegalArgumentException::class.java) {
            DurableLocalState(byteDirectory).saveDraft("a", "session:new:prompt", JSONObject().put("text", "n".repeat(2 * 1024 * 1024)))
        }
        assertArrayEquals(byteBefore, byteFile.readBytes())
        assertEquals(setOf(protected.getString("id"), final.getString("id")), records(DurableLocalState(byteDirectory)).keys)
        assertNull(DurableLocalState(byteDirectory).draft("a", "session:new:prompt"))
    }

    @Test fun explicitRemovalRejectsUnresolvedAndUnappliedEffectsButAllowsSafeFinals() {
        val directory = temporary.newFolder()
        val protected = listOf(
            operation(), operation(status = "running"),
            operation(status = "succeeded").put("draftSubmission", JSONObject()),
            operation(status = "succeeded").put("branchRestore", JSONObject()).put("draftEffect", JSONObject.NULL),
            operation(status = "succeeded").put("branchRestore", JSONObject()).put("draftEffect", "review")
        )
        val removable = listOf(
            operation(status = "failed").put("draftSubmission", JSONObject()),
            operation(status = "succeeded").put("draftSubmission", JSONObject()).put("draftEffect", "cleared"),
            operation(status = "succeeded").put("branchRestore", JSONObject()).put("draftEffect", "restored")
        )
        val file = seed(directory, protected + removable)
        val state = DurableLocalState(directory)
        protected.forEach { record ->
            val before = file.readBytes()
            assertThrows(IllegalArgumentException::class.java) { state.removeOperation("a", record.getString("id")) }
            assertArrayEquals(before, file.readBytes())
        }
        removable.forEach { state.removeOperation("a", it.getString("id")) }
        assertEquals(protected.map { it.getString("id") }.toSet(), records(DurableLocalState(directory)).keys)
        state.removeOperation("a", UUID.randomUUID().toString())
    }

    @Test fun retentionStillRejectsConflictingRequestsAndLateFinalRegression() {
        val directory = temporary.newFolder()
        val completed = operation(status = "succeeded")
        val file = seed(directory, listOf(completed) + (1..999).map { operation(status = "failed") })
        val before = file.readBytes()
        val changed = JSONObject(completed.toString())
        changed.getJSONObject("request").put("action", "session.abort")
        val state = DurableLocalState(directory)
        assertThrows(IllegalArgumentException::class.java) { state.saveOperation("a", changed) }
        assertArrayEquals(before, file.readBytes())
        state.saveOperation("a", JSONObject().put("id", completed.getString("id")).put("status", "unknown"))
        assertArrayEquals(before, file.readBytes())
    }

    @Test fun legacyOutcomeUnknownFailuresReopenAsProtectedUnknownWithoutLosingRequestsOrDrafts() {
        val directory = temporary.newFolder()
        val uncertain = operation(status = "failed").put("createdAt", "2000-01-01T00:00:00Z")
            .put("result", JSONObject().put("status", "failed").put("success", false)
                .put("error", JSONObject().put("code", "outcome_unknown").put("message", "ACK lost")))
        val ordinaryFailure = operation(status = "failed").put("createdAt", "2001-01-01T00:00:00Z")
            .put("result", JSONObject().put("status", "failed").put("error", JSONObject().put("code", "invalid_request")))
        val succeeded = operation(status = "succeeded").put("createdAt", "2026-01-01T00:00:00Z")
            .put("result", JSONObject().put("status", "succeeded").put("error", JSONObject().put("code", "outcome_unknown")))
        val draft = JSONObject().put("text", "Unsent exact draft").put("_revision", UUID.randomUUID().toString())
        val file = seed(directory, listOf(uncertain, ordinaryFailure, succeeded) + (1..997).map {
            operation(status = "failed").put("createdAt", "2026-01-01T00:00:00Z")
        }, draft)
        val state = DurableLocalState(directory)
        val reopened = records(state)
        val migrated = reopened.getValue(uncertain.getString("id"))
        assertEquals("unknown", migrated.getString("status"))
        assertEquals("unknown", migrated.getJSONObject("result").getString("status"))
        assertEquals(uncertain.getJSONObject("request").toString(), migrated.getJSONObject("request").toString())
        assertEquals(uncertain.getJSONObject("result").getJSONObject("error").toString(), migrated.getJSONObject("result").getJSONObject("error").toString())
        assertEquals(ordinaryFailure.toString(), reopened.getValue(ordinaryFailure.getString("id")).toString())
        assertEquals(succeeded.toString(), reopened.getValue(succeeded.getString("id")).toString())
        val before = file.readBytes()
        assertThrows(IllegalArgumentException::class.java) { state.removeOperation("a", uncertain.getString("id")) }
        assertArrayEquals(before, file.readBytes())
        val incoming = operation()
        state.saveOperation("a", incoming)
        val after = records(DurableLocalState(directory))
        assertEquals(1000, after.size)
        assertTrue(after.containsKey(uncertain.getString("id")))
        assertFalse(after.containsKey(ordinaryFailure.getString("id")))
        assertEquals("unknown", JSONObject(file.readText()).getJSONObject("operations").getJSONObject(uncertain.getString("id")).getString("status"))
        assertEquals(draft.toString(), DurableLocalState(directory).draft("a", "session:s:prompt")!!.toString())
        state.saveOperation("a", JSONObject().put("id", uncertain.getString("id")).put("status", "running")
            .put("result", JSONObject().put("status", "running")))
        assertEquals("running", records(DurableLocalState(directory)).getValue(uncertain.getString("id")).getString("status"))
    }

    @Test fun incomingOutcomeUnknownFailureCannotBecomeFinalOrRegressTrueSuccess() {
        val directory = temporary.newFolder()
        val state = DurableLocalState(directory)
        val uncertain = operation(status = "failed").put("result", JSONObject().put("status", "failed")
            .put("error", JSONObject().put("code", "outcome_unknown")))
        state.saveOperation("a", uncertain)
        val stored = JSONObject(directory.listFiles()!!.single().readText()).getJSONObject("operations").getJSONObject(uncertain.getString("id"))
        assertEquals("unknown", stored.getString("status"))
        assertEquals("unknown", stored.getJSONObject("result").getString("status"))
        assertEquals(uncertain.getJSONObject("request").toString(), stored.getJSONObject("request").toString())
        assertThrows(IllegalArgumentException::class.java) { state.removeOperation("a", uncertain.getString("id")) }
        state.saveOperation("a", JSONObject().put("id", uncertain.getString("id")).put("status", "succeeded")
            .put("result", JSONObject().put("status", "succeeded").put("success", true)))
        state.saveOperation("a", uncertain)
        val final = records(DurableLocalState(directory)).getValue(uncertain.getString("id"))
        assertEquals("succeeded", final.getString("status"))
        assertTrue(final.getJSONObject("result").getBoolean("success"))
    }
    @Test fun answerReadAndDeliverySurviveRestartSeparatelyAndNeverRegress() {
        val directory = temporary.newFolder()
        val summary = AnswerPolicy.Summary("generation", 3,
            AnswerPolicy.Reference("m3", 1, 30, 3, "Safe final answer"))
        fun marker(ordinal: Int, revision: Int = 1) = AnswerPolicy.Marker("epoch", "generation",
            ordinal.toLong(), "m$ordinal", revision.toLong(), ordinal * 10L).json()
        val state = DurableLocalState(directory)
        state.commitAnswerRead("pc:phone", "session:s", summary, "epoch", marker(2))
        state.commitAnswerRead("pc:phone", "session:s", summary, "epoch", marker(1))
        state.set("pc:phone", "notificationDelivery", "session:s", marker(3))
        val restarted = DurableLocalState(directory)
        val sections = restarted.state("pc:phone").getJSONObject("sections")
        assertEquals(2L, sections.getJSONObject("read").getJSONObject("session:s").getLong("ordinal"))
        assertEquals(3L, sections.getJSONObject("notificationDelivery").getJSONObject("session:s").getLong("ordinal"))
        assertEquals(1L, AnswerPolicy.unread(summary, "epoch", sections.getJSONObject("read").getJSONObject("session:s")))
        assertEquals(0, restarted.state("another:phone").getJSONObject("sections").getJSONObject("read").length())
        restarted.clear()
        assertEquals(0, restarted.state("pc:phone").getJSONObject("sections").getJSONObject("notificationDelivery").length())
    }

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
    @Test fun mergedOperationLimitRejectsOversizedResultWithoutChangingCommittedRequest() {
        val directory = temporary.newFolder()
        val state = DurableLocalState(directory)
        val record = operation()
        record.getJSONObject("request").getJSONObject("payload").put("text", "r".repeat(4 * 1024 * 1024))
        state.saveOperation("a", record)
        val file = directory.listFiles()!!.single()
        val before = file.readBytes()
        val update = JSONObject().put("id", record.getString("id")).put("status", "succeeded")
            .put("result", JSONObject().put("text", "s".repeat(3 * 1024 * 1024)))
        assertTrue(update.toString().toByteArray(Charsets.UTF_8).size < DurableLocalState.MAX_OPERATION_BYTES)
        assertThrows(IllegalArgumentException::class.java) { state.saveOperation("a", update) }
        assertArrayEquals(before, file.readBytes())
        val retained = DurableLocalState(directory).operations("a").getJSONObject(0)
        assertEquals("unknown", retained.getString("status"))
        assertEquals(record.getJSONObject("request").toString(), retained.getJSONObject("request").toString())
        assertFalse(retained.has("result"))
        update.put("result", JSONObject().put("text", "s".repeat(1024 * 1024)))
        state.saveOperation("a", update)
        val completed = DurableLocalState(directory).operations("a").getJSONObject(0)
        assertEquals("succeeded", completed.getString("status"))
        assertEquals(record.getJSONObject("request").toString(), completed.getJSONObject("request").toString())
        assertEquals(1024 * 1024, completed.getJSONObject("result").getString("text").length)
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
