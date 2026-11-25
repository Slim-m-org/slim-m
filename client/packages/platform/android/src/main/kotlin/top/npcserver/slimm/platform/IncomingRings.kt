// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationManagerCompat

/**
 * The rings this process is showing, and how long each lasts.
 *
 * Nothing here touches the app's own window: the only surface drawn over the lock screen is
 * [IncomingCallActivity], which [watch]es its ring and closes when it ends.
 */
object IncomingRings {
    /** Matches the server's `RING_TIMEOUT` (`voice/ring.rs`), so a ring whose end push never arrives still stops. */
    const val RING_TIMEOUT_MS = 30_000L

    private val main = Handler(Looper.getMainLooper())
    private val timeouts = mutableMapOf<String, Runnable>()
    private val watchers = mutableMapOf<String, MutableList<() -> Unit>>()

    /** A repeat of [callId] restarts its timer instead of adding a second one. */
    fun begin(context: Context, callId: String) {
        val appContext = context.applicationContext
        timeouts.remove(callId)?.let(main::removeCallbacks)
        val expire = Runnable { expire(appContext, callId) }
        timeouts[callId] = expire
        main.postDelayed(expire, RING_TIMEOUT_MS)
    }

    fun isLive(callId: String): Boolean = timeouts.containsKey(callId)

    /** Runs [onEnd] once when the ring for [callId] ends; returns what to call to stop watching. */
    fun watch(callId: String, onEnd: () -> Unit): () -> Unit {
        watchers.getOrPut(callId) { mutableListOf() }.add(onEnd)
        return { watchers[callId]?.remove(onEnd) }
    }

    fun finish(callId: String) {
        timeouts.remove(callId)?.let(main::removeCallbacks)
        watchers.remove(callId)?.forEach { it() }
    }

    fun finishAll() {
        timeouts.values.forEach(main::removeCallbacks)
        timeouts.clear()
        watchers.values.flatten().forEach { it() }
        watchers.clear()
    }

    /** The caller never got an answer: nothing of this ring may outlive it. */
    private fun expire(context: Context, callId: String) {
        SlimmConnection.registry[callId]?.endAsMissed()
        NotificationManagerCompat.from(context).cancel(IncomingCallNotifier.notificationIdFor(callId))
        finish(callId)
    }

    /** The user answered from the notification (or Telecom did): the ring is over and Dart joins the call. */
    fun answered(context: Context, callId: String) {
        SlimmConnection.registry[callId]?.endAnswered()
        NotificationManagerCompat.from(context).cancel(IncomingCallNotifier.notificationIdFor(callId))
        finish(callId)
        CallEvents.emit(context, CallEvent.ANSWERED, callId)
    }

    /** The user declined from the notification (or Telecom did): Dart tells the server. */
    fun declined(context: Context, callId: String) {
        val connection = SlimmConnection.registry[callId]
        if (connection != null) {
            connection.onReject()
            return
        }
        NotificationManagerCompat.from(context).cancel(IncomingCallNotifier.notificationIdFor(callId))
        finish(callId)
        CallEvents.emit(context, CallEvent.DECLINED, callId)
    }
}
