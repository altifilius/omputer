package dev.omputer.omputer

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.time.Instant

class NativeReliabilityTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun message(id: String, revision: Int = 1) = JSONObject().put("id", id).put("revision", revision).put("content", "revision-$revision")
    private fun page(vararg messages: JSONObject) = JSONObject().put("messages", JSONArray(messages.toList())).put("hasMore", false)

    @Test fun busyUiKeepsLatestMessageAndSnapshotWithoutUnboundedQueue() {
        val buffer = NativeEventBuffer(maxEvents = 2, maxChars = 100)
        buffer.offer(NativeEventBuffer.Event("snapshot", "old", 1))
        buffer.offer(NativeEventBuffer.Event("snapshot", "latest", 1))
        repeat(1000) { buffer.offer(NativeEventBuffer.Event("event", it, 1, 10), "message:same") }
        val drained = buffer.drain(1)
        assertEquals(listOf("latest", 999), drained.map { it.data })
    }
    @Test fun overflowInvalidatesTranscriptsAndRejectsPriorPairQueuedEvents() {
        val buffer = NativeEventBuffer(maxEvents = 2, maxChars = 100)
        repeat(3) { buffer.offer(NativeEventBuffer.Event("event", it, 1, 10), "message:$it") }
        val drained = buffer.drain(1)
        assertEquals("history_reset", drained.first().type)
        assertEquals(2, drained.last().data)
        buffer.offer(NativeEventBuffer.Event("snapshot", "old pc", 1))
        buffer.offer(NativeEventBuffer.Event("event", "old text", 1, 10), "message:old")
        assertTrue(buffer.drain(2).isEmpty())
    }
    @Test fun semanticCommandFailuresNeverCountAsAcceptedReplies() {
        assertEquals("answer_invalid" to "Choose one", DecisionPolicy.commandError(JSONObject()
            .put("success", true).put("data", JSONObject().put("accepted", false)
                .put("error", JSONObject().put("code", "answer_invalid").put("message", "Choose one")))))
        assertNotNull(DecisionPolicy.commandError(JSONObject().put("success", false).put("error", "Already answered")))
        assertNull(DecisionPolicy.commandError(JSONObject().put("success", true)))
    }
    @Test fun expiredResolvedAndMalformedDecisionsCannotNotifyOrReply() {
        val now = Instant.parse("2026-10-18T12:00:00Z")
        val request = JSONObject().put("status", "pending").put("expiresAt", now.toString())
        assertFalse(DecisionPolicy.pending(request, now))
        request.put("expiresAt", "invalid")
        assertFalse(DecisionPolicy.pending(request, now))
        request.put("expiresAt", "2026-10-18T12:00:01Z")
        assertTrue(DecisionPolicy.pending(request, now))
        request.put("status", "resolved")
        assertFalse(DecisionPolicy.pending(request, now))
    }
    @Test fun cacheBoundsBytesAndNeverScansUnrelatedCorruptPageForLiveMessage() {
        val directory = temporary.newFolder()
        val cache = ResponseCache(directory, maxBytes = 1600, maxEntries = 2, maxEntryBytes = 1000)
        val path = "/v1/sessions/s/messages?limit=50"
        cache.put(path, page(message("a", 3)))
        java.io.File(directory, "unrelated.json").writeText("broken")
        cache.updateMessage("s", message("a", 1))
        assertEquals(3, cache.get(path)!!.getJSONArray("messages").getJSONObject(0).getInt("revision"))
        cache.put("/v1/models", JSONObject().put("text", "x".repeat(1001)))
        assertNull(cache.get("/v1/models"))
        repeat(4) { cache.put("/v1/projects/$it/files?path=x", JSONObject().put("text", "x".repeat(300))) }
        assertTrue(directory.listFiles()!!.filter { it.name != "unrelated.json" }.sumOf { it.length() } <= 1600)
        assertNull(cache.get(path))
    }
    @Test fun transcriptResetRetiresOnlyExactSessionAndOldBranchCannotReturn() {
        val cache = ResponseCache(temporary.newFolder())
        val path = "/v1/sessions/s/messages?limit=50"
        val other = "/v1/sessions/sibling/messages?limit=50"
        cache.put(path, page(message("old")))
        cache.put(other, page(message("other")))
        cache.resetMessages("s")
        cache.updateMessage("s", message("replacement"))
        assertNull(cache.get(path))
        assertEquals("other", cache.get(other)!!.getJSONArray("messages").getJSONObject(0).getString("id"))
        cache.put(path, page(message("replacement")))
        assertEquals(1, cache.get(path)!!.getJSONArray("messages").length())
    }
    @Test fun restartingUnderDifferentPairCannotRecoverPreviousComputerPages() {
        val directory = temporary.newFolder()
        val path = "/v1/sessions/s/messages"
        ResponseCache(directory, identity = "phone-a").put(path, page(message("private")))
        assertNotNull(ResponseCache(directory, identity = "phone-a").get(path))
        assertNull(ResponseCache(directory, identity = "phone-b").get(path))
    }
}
