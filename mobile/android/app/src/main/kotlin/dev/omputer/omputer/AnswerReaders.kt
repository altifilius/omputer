package dev.omputer.omputer

/** Transient viewport claims; real Activity lifecycle always wins over Dart. */
internal class AnswerReaders {
    private data class Reader(val session: String, val epoch: String, val generation: String)
    private var resumed = false
    private val owners = linkedMapOf<String, Reader>()

    fun activityResumed(resumed: Boolean) {
        this.resumed = resumed
        if (!resumed) clear()
    }
    fun update(owner: String, session: String?, epoch: String?, generation: String?, atLatest: Boolean) {
        require(owner.isNotBlank() && owner.length <= 512) { "Yanıt okuyucusu kimliği geçersiz." }
        owners.remove(owner)
        if (!atLatest || session == null || !resumed) return
        require(listOf(session, epoch, generation).all { !it.isNullOrBlank() && it.length <= 512 }) { "Yanıt okuyucusu geçmişi eksik." }
        require(owners.size < 64) { "Çok fazla yanıt okuyucusu açık." }
        owners[owner] = Reader(session, epoch!!, generation!!)
    }
    fun visible(session: String, epoch: String, generation: String): Boolean =
        resumed && owners.values.any { it == Reader(session, epoch, generation) }
    fun clear() { owners.clear() }
}
