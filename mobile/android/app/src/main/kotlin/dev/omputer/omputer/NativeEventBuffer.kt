package dev.omputer.omputer

/** A single main-loop drain replaces queued UI work; the PC retains full history. */
internal class NativeEventBuffer(private val maxEvents: Int = 128, private val maxChars: Int = 512 * 1024) {
    data class Event(val type: String, val data: Any?, val generation: Int, val chars: Int = 0)
    private val states = linkedMapOf<String, Event>()
    private val journal = linkedMapOf<String, Event>()
    private var chars = 0

    @Synchronized fun offer(event: Event, key: String = event.type) {
        if (event.type != "event") {
            states[key] = event
            return
        }
        journal.remove(key)?.let { chars -= it.chars }
        if (event.chars > maxChars || journal.size >= maxEvents || chars + event.chars > maxChars) {
            journal.clear(); chars = 0
            states["history_reset"] = Event("history_reset", emptyMap<String, Any?>(), event.generation)
            if (event.chars > maxChars) return
        }
        journal[key] = event
        chars += event.chars
    }

    @Synchronized fun drain(generation: Int): List<Event> {
        val result = ArrayList<Event>(states.size + journal.size)
        // The latest snapshot is authoritative before transcript invalidation/upserts.
        for (key in listOf("connection", "snapshot", "discovery", "history_reset")) states.remove(key)?.let { result.add(it) }
        result.addAll(journal.values)
        result.addAll(states.values)
        states.clear(); journal.clear(); chars = 0
        return result.filter { it.type in setOf("navigate", "discovery") || it.generation == generation }
    }
}
