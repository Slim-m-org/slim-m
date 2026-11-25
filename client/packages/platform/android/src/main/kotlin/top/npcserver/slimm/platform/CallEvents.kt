// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.content.Context

/**
 * Carries an answered or declined ring from native code to Dart.
 *
 * An event goes to every engine that has asked for live delivery; with none, it is kept in
 * preferences until [takePending], so a decline tapped while no Dart runs still reaches the
 * server when the app next starts.
 */
object CallEvents {
    private const val PREFS = "slimm_call_events"
    private const val KEY = "pending"
    private const val KEPT = 16

    private val live = mutableSetOf<CallKitBridge>()

    fun emit(context: Context, kind: String, id: String) {
        val event = CallEvent(kind, id)
        val sinks = synchronized(live) { live.toList() }
        if (sinks.isEmpty()) {
            val kept = CallEventCodec.decode(prefs(context).getString(KEY, null)) + event
            prefs(context).edit().putString(KEY, CallEventCodec.encode(CallEventCodec.capped(kept, KEPT))).commit()
        } else {
            sinks.forEach { it.send(event) }
        }
    }

    /** Held events, oldest first; asking also switches [bridge] to live delivery. */
    fun takePending(context: Context, bridge: CallKitBridge): List<CallEvent> {
        synchronized(live) { live.add(bridge) }
        val held = CallEventCodec.decode(prefs(context).getString(KEY, null))
        prefs(context).edit().remove(KEY).commit()
        return held
    }

    fun release(bridge: CallKitBridge) {
        synchronized(live) { live.remove(bridge) }
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
