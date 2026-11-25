// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationManagerCompat

/**
 * Handles the incoming-call notification's Decline action.
 *
 * Answer is an activity intent on the notification itself, since Android 12 blocks an activity
 * started from a receiver. The notification is cancelled here whatever else happens, and the
 * decline is handed to [IncomingRings] so Dart tells the server.
 */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val notificationId = intent.getIntExtra(EXTRA_NOTIFICATION_ID, -1)
        if (notificationId != -1) {
            NotificationManagerCompat.from(context).cancel(notificationId)
        }
        val callId = intent.getStringExtra(EXTRA_CALL_ID) ?: return
        if (intent.action == ACTION_DECLINE) IncomingRings.declined(context, callId)
    }

    companion object {
        const val ACTION_DECLINE = "top.npcserver.slimm.action.DECLINE_CALL"
        const val EXTRA_NOTIFICATION_ID = "notification_id"
        const val EXTRA_CALL_ID = "call_id"
    }
}
