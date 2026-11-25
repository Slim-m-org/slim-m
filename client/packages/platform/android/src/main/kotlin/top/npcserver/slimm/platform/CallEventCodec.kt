// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

/** What the notification or Telecom did to a ring, told to Dart as `onCallKitEvent`. */
data class CallEvent(val kind: String, val id: String, val atMs: Long = 0L) {
    /** [id] is the server's ring id here, so Dart may only act on that ring. */
    fun toMap(): Map<String, Any> = mapOf("event" to kind, "id" to id, "ring_id" to true)

    companion object {
        const val ANSWERED = "answered"
        const val DECLINED = "declined"
    }
}

/** Flattens held events to one string, since the process may die before Dart asks for them. */
object CallEventCodec {
    private const val FIELD = '\t'
    private const val ROW = '\n'

    fun encode(events: List<CallEvent>): String =
        events.joinToString(ROW.toString()) { "${it.kind}$FIELD${clean(it.id)}$FIELD${it.atMs}" }

    fun decode(raw: String?): List<CallEvent> =
        raw.orEmpty().split(ROW).mapNotNull { row ->
            val parts = row.split(FIELD)
            if (parts.size == 3 && parts[0].isNotEmpty() && parts[1].isNotEmpty()) {
                CallEvent(parts[0], parts[1], parts[2].toLongOrNull() ?: 0L)
            } else {
                null
            }
        }

    /** The newest [limit] events: an app that never opens must not grow this without bound. */
    fun capped(events: List<CallEvent>, limit: Int): List<CallEvent> = events.takeLast(limit)

    /** Events no older than [maxAgeMs]: a held answer or decline from an earlier ring must not act on a later one. */
    fun fresh(events: List<CallEvent>, nowMs: Long, maxAgeMs: Long): List<CallEvent> =
        events.filter { it.atMs in (nowMs - maxAgeMs)..nowMs }

    private fun clean(id: String): String = id.replace(FIELD, ' ').replace(ROW, ' ')
}
