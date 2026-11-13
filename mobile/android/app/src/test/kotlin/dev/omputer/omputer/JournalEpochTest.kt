package dev.omputer.omputer

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class JournalEpochTest {
    private fun snapshot(epoch: String?, sequence: Long) = JSONObject().put("sequence", sequence).also {
        if (epoch != null) it.put("journalEpoch", epoch)
    }

    @Test fun restoredAuthenticatedEpochResetsLowerWatermarkWithoutAcceptingLateOldSnapshots() {
        val before = snapshot("before", 51)
        val restored = snapshot("restored", 3)
        assertTrue(JournalEpoch.accepts(before, restored, true, emptySet()))
        assertFalse(JournalEpoch.accepts(before, restored, false, emptySet()))
        assertTrue(JournalEpoch.changes(before, restored))
        assertFalse(JournalEpoch.accepts(restored, snapshot("before", 60), true, setOf("before")))
        assertFalse(JournalEpoch.accepts(restored, snapshot("restored", 2), true, setOf("before")))
        assertTrue(JournalEpoch.accepts(restored, snapshot("restored", 3), false, setOf("before")))
        assertTrue(JournalEpoch.accepts(restored, snapshot("restored", 4), false, setOf("before")))
    }

    @Test fun firstEpochUpgradesCachedLegacyStateButNeverSilentlyDowngradesLiveState() {
        val legacy = snapshot(null, 100)
        val authenticated = snapshot("new", 1)
        assertTrue(JournalEpoch.accepts(legacy, authenticated, true, emptySet()))
        assertFalse(JournalEpoch.accepts(legacy, authenticated, false, emptySet()))
        assertFalse(JournalEpoch.accepts(authenticated, snapshot(null, 101), true, emptySet()))
        assertFalse(JournalEpoch.accepts(legacy, snapshot(null, 99), true, emptySet()))
    }
}
