// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

/** What the notification or Telecom did to a ring, told to Dart as `onCallKitEvent`. */
data class CallEvent(val kind: String, val id: String) {
    fun toMap(): Map<String, String> = mapOf("event" to kind, "id" to id)

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
        events.joinToString(ROW.toString()) { "${it.kind}$FIELD${clean(it.id)}" }

    fun decode(raw: String?): List<CallEvent> =
        raw.orEmpty().split(ROW).mapNotNull { row ->
            val parts = row.split(FIELD)
            if (parts.size == 2 && parts[0].isNotEmpty() && parts[1].isNotEmpty()) {
                CallEvent(parts[0], parts[1])
            } else {
                null
            }
        }

    /** The newest [limit] events: an app that never opens must not grow this without bound. */
    fun capped(events: List<CallEvent>, limit: Int): List<CallEvent> = events.takeLast(limit)

    private fun clean(id: String): String = id.replace(FIELD, ' ').replace(ROW, ' ')
}
