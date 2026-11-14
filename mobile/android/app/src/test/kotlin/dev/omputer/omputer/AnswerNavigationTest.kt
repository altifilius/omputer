package dev.omputer.omputer

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AnswerNavigationTest {
    private val target = AnswerNavigation.Target.create("s", "pair", "epoch", "generation")!!
    private fun snapshot(epoch: String = "epoch", generation: String? = "generation"): JSONObject {
        val session = JSONObject().put("id", "s")
        if (generation != null) session.put("answerSummary", JSONObject().put("generation", generation).put("count", 1)
            .put("latest", JSONObject().put("messageId", "m").put("revision", 1).put("sequence", 10)
                .put("ordinal", 1).put("preview", "Answer")))
        return JSONObject().put("journalEpoch", epoch).put("sessions", JSONArray().put(session))
    }

    @Test fun coldTapWaitsForAuthenticatedSnapshotInsteadOfConsumingMissingOrOlderCache() {
        for (cached in listOf(JSONObject(), snapshot(generation = null), snapshot(generation = "older"), snapshot())) {
            val navigation = AnswerNavigation()
            navigation.resetIdentity("pair")
            navigation.snapshot(cached, authenticated = false)
            assertTrue("A valid scoped tap must survive cached startup", navigation.request(target))
            assertNull("Even a matching cached snapshot is not navigation authority", navigation.pendingTicket())
            navigation.snapshot(snapshot(), authenticated = true)
            val ticket = navigation.pendingTicket()!!
            val delivered = mutableListOf<Map<String, Any?>>()
            assertTrue(navigation.deliver(ticket, delivered::add))
            assertEquals(listOf(mapOf("sessionId" to "s", "answer" to true)), delivered)
            assertNull(navigation.pendingTicket())
            assertFalse(navigation.deliver(ticket, delivered::add))
            assertEquals(1, delivered.size)
        }
    }

    @Test fun queuedTicketIsRejectedAtActualUiDeliveryAfterEpochOrGenerationChanges() {
        for (replacement in listOf(snapshot(epoch = "restored"), snapshot(generation = "branch"),
            snapshot(generation = null), JSONObject().put("journalEpoch", "epoch").put("sessions", JSONArray()))) {
            val navigation = AnswerNavigation()
            val buffer = NativeEventBuffer()
            navigation.resetIdentity("pair")
            navigation.snapshot(snapshot(), authenticated = true)
            assertTrue(navigation.request(target))
            val ticket = navigation.pendingTicket()!!
            buffer.offer(NativeEventBuffer.Event("navigate", ticket, 1))
            // resetJournal intentionally preserves unrelated navigation across reconnect.
            // A scoped answer still needs final admission even after drain copied its ticket.
            buffer.resetJournal()
            val drained = buffer.drain(2).single().data as AnswerNavigation.Ticket
            navigation.snapshot(replacement, authenticated = true)
            val delivered = mutableListOf<Map<String, Any?>>()
            assertFalse("A queued ticket cannot become navigation in a replacement history",
                navigation.deliver(drained, delivered::add))
            assertTrue(delivered.isEmpty())
            navigation.snapshot(snapshot(), authenticated = true)
            assertNull("Retired targets must not be reinterpreted if their old scope returns", navigation.pendingTicket())
            assertFalse(navigation.deliver(ticket, delivered::add))
        }
    }

    @Test fun bootstrapMismatchRetiresColdTapRatherThanReinterpretingLaterBranch() {
        val navigation = AnswerNavigation()
        navigation.resetIdentity("pair")
        assertTrue(navigation.request(target))
        navigation.snapshot(snapshot(generation = "replacement"), authenticated = true)
        assertNull(navigation.pendingTicket())
        navigation.snapshot(snapshot(), authenticated = true)
        assertNull(navigation.pendingTicket())
    }

    @Test fun pairingReplacementForgetAndRevocationRetireEvenAlreadyDrainedTickets() {
        for (identity in listOf("replacement-pair", null, "pair")) {
            val navigation = AnswerNavigation()
            navigation.resetIdentity("pair")
            navigation.snapshot(snapshot(), authenticated = true)
            assertTrue(navigation.request(target))
            val ticket = navigation.pendingTicket()!!
            navigation.resetIdentity(identity)
            navigation.snapshot(snapshot(), authenticated = true)
            assertNull(navigation.pendingTicket())
            assertFalse(navigation.deliver(ticket) { fail("Old pairing target reached UI") })
        }
    }

    @Test fun ordinaryReconnectKeepsTheScopedTicketButNewerNavigationSupersedesIt() {
        val navigation = AnswerNavigation()
        val buffer = NativeEventBuffer()
        navigation.resetIdentity("pair")
        navigation.snapshot(snapshot(), authenticated = true)
        assertTrue(navigation.request(target))
        val ticket = navigation.pendingTicket()!!
        buffer.offer(NativeEventBuffer.Event("navigate", ticket, 1))
        buffer.resetJournal()
        navigation.snapshot(snapshot(), authenticated = true)
        val queued = buffer.drain(2).single().data as AnswerNavigation.Ticket
        assertTrue(navigation.deliver(queued) { assertEquals(mapOf("sessionId" to "s", "answer" to true), it) })
        assertTrue(navigation.request(target))
        val superseded = navigation.pendingTicket()!!
        navigation.clear()
        assertFalse(navigation.deliver(superseded) { fail("Superseded tap reached UI") })
    }
}
