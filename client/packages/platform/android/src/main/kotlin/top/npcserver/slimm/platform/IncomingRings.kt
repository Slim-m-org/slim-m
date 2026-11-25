// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import androidx.core.app.NotificationManagerCompat
import java.lang.ref.WeakReference

/**
 * The rings this process is showing: how long each lasts, and whether the app may draw over the
 * lock screen while one does.
 *
 * The window flags are set only while a ring is live and cleared with the last one, so slim-m
 * never stays visible over the lock screen once the call is answered, declined or missed.
 */
object IncomingRings {
    /** Matches the server's `RING_TIMEOUT` (`voice/ring.rs`), so a ring whose end push never arrives still stops. */
    const val RING_TIMEOUT_MS = 30_000L

    private val main = Handler(Looper.getMainLooper())
    private val timeouts = mutableMapOf<String, Runnable>()
    private var activity: WeakReference<Activity>? = null

    /** A repeat of [callId] restarts its timer instead of adding a second one. */
    fun begin(context: Context, callId: String) {
        val appContext = context.applicationContext
        timeouts.remove(callId)?.let(main::removeCallbacks)
        val expire = Runnable { expire(appContext, callId) }
        timeouts[callId] = expire
        main.postDelayed(expire, RING_TIMEOUT_MS)
        applyLockScreen()
    }

    fun finish(callId: String) {
        timeouts.remove(callId)?.let(main::removeCallbacks)
        applyLockScreen()
    }

    fun finishAll() {
        timeouts.values.forEach(main::removeCallbacks)
        timeouts.clear()
        applyLockScreen()
    }

    /** The caller never got an answer: nothing of this ring may outlive it. */
    private fun expire(context: Context, callId: String) {
        SlimmConnection.registry[callId]?.endAsMissed()
        NotificationManagerCompat.from(context).cancel(IncomingCallNotifier.notificationIdFor(callId))
        finish(callId)
    }

    fun activityAttached(attached: Activity) {
        activity = WeakReference(attached)
        applyLockScreen()
    }

    fun activityDetached(detached: Activity) {
        if (activity?.get() === detached) {
            setOverLockScreen(detached, false)
            activity = null
        }
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

    private fun applyLockScreen() {
        val current = activity?.get() ?: return
        setOverLockScreen(current, timeouts.isNotEmpty())
    }

    @Suppress("DEPRECATION")
    private fun setOverLockScreen(target: Activity, over: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            target.setShowWhenLocked(over)
            target.setTurnScreenOn(over)
            return
        }
        val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        if (over) target.window.addFlags(flags) else target.window.clearFlags(flags)
    }
}
