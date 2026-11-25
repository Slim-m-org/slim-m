// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.content.Context
import android.net.Uri
import android.telecom.Connection
import android.telecom.DisconnectCause
import android.telecom.TelecomManager
import androidx.core.app.NotificationManagerCompat

/**
 * One incoming ring reported to `android.telecom`, ended by whichever comes first: an answer, a
 * decline, the caller giving up, or the ring timeout. The call itself, once joined, is
 * [SlimmOngoingConnection]; answering ends this ring because the notification already hands the
 * answer to the app.
 */
class SlimmConnection(
    private val context: Context,
    private val callId: String,
    callerName: String,
) : Connection() {
    init {
        setCallerDisplayName(callerName, TelecomManager.PRESENTATION_ALLOWED)
        setAddress(
            Uri.fromParts(ADDRESS_SCHEME, callId, null),
            TelecomManager.PRESENTATION_ALLOWED,
        )
        // Both are inherited `public static final int` fields declared
        // directly on `Connection`; Kotlin resolves an unqualified static
        // reference from a Java superclass the same way Java itself does.
        connectionProperties = PROPERTY_SELF_MANAGED
        connectionCapabilities = CAPABILITY_MUTE
        setAudioModeIsVoip(true)
    }

    /**
     * Telecom answered the ring itself (a paired headset's answer button, say). The app is
     * told it was answered, and opened with the answered extra when the system allows it.
     */
    override fun onAnswer() {
        setActive()
        IncomingRings.answered(context, callId)
        try {
            context.startActivity(IncomingCallNotifier.answerIntent(context, callId))
        } catch (_: RuntimeException) {
            // Background activity starts can be refused; the answer already reached Dart through the event above.
        }
    }

    /** The notification's Decline, or Telecom driving a reject, both converge here and tell Dart. */
    override fun onReject() {
        end(DisconnectCause.REJECTED)
        CallEvents.emit(context, CallEvent.DECLINED, callId)
    }

    /** Telecom ending this call through any path neither of the above already covers. */
    override fun onDisconnect() {
        end(DisconnectCause.LOCAL)
    }

    /** The ring ended on the caller's side or timed out; nobody here answered. */
    fun endAsMissed() {
        end(DisconnectCause.MISSED)
    }

    /** The app took over the answer, so Telecom is done with this ring without opening anything. */
    fun endAnswered() {
        end(DisconnectCause.LOCAL)
    }

    /** Replaced by a repeat push for the same call: the notification now belongs to the new connection. */
    fun endReplaced() {
        end(DisconnectCause.CANCELED, cancelNotification = false)
    }

    private fun end(reason: Int, cancelNotification: Boolean = true) {
        setDisconnected(DisconnectCause(reason))
        destroy()
        registry.remove(callId, this)
        if (cancelNotification) {
            NotificationManagerCompat.from(context)
                .cancel(IncomingCallNotifier.notificationIdFor(callId))
            IncomingRings.finish(callId)
        }
    }

    companion object {
        const val EXTRA_CALL_ID = "top.npcserver.slimm.extra.CALL_ID"
        const val EXTRA_CALLER_NAME = "top.npcserver.slimm.extra.CALLER_NAME"
        private const val ADDRESS_SCHEME = "slimm-call"

        /** Ringing connections by call id, in this process only: a ring cannot outlive it. */
        val registry = mutableMapOf<String, SlimmConnection>()
    }
}
