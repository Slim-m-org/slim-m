// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.content.Context
import android.os.Build
import android.os.Bundle
import android.telecom.TelecomManager

/**
 * Keeps one self-managed Telecom call in step with the app's own voice call.
 *
 * Telecom builds the connection asynchronously, so a "connected" report that arrives first is
 * remembered and applied when the connection shows up.
 */
object ActiveCall {
    private var callId: String? = null
    private var connected = false
    private var connection: SlimmOngoingConnection? = null

    fun start(context: Context, id: String, displayName: String) {
        end(id = null)
        callId = id
        connected = false
        placeCall(context, id, displayName)
    }

    fun connected(id: String) {
        if (id != callId) return
        connected = true
        connection?.markConnected()
    }

    /** [id] null ends whatever is live, for a new call starting over an old one. */
    fun end(id: String?) {
        if (id != null && id != callId) return
        connection?.endFromApp()
        connection = null
        callId = null
        connected = false
    }

    fun connectionCreated(created: SlimmOngoingConnection) {
        if (created.callId != callId) {
            created.endFromApp()
            return
        }
        connection = created
        if (connected) created.markConnected()
    }

    fun endedBySystem(ended: SlimmOngoingConnection) {
        if (connection !== ended) return
        connection = null
        callId = null
        connected = false
        CallLifecycleBridge.requestEnd()
    }

    private fun placeCall(context: Context, id: String, displayName: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val telecom = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager ?: return
        val handle = IncomingCallNotifier.registerAccount(context, telecom)
        val extras = Bundle().apply {
            putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
            putString(SlimmConnection.EXTRA_CALLER_NAME, displayName)
        }
        try {
            telecom.placeCall(SlimmOngoingConnection.addressFor(id), extras)
        } catch (_: SecurityException) {
            // MANAGE_OWN_CALLS refused; the app's own call carries on without a Telecom entry.
        } catch (_: IllegalArgumentException) {
            // The account is not usable; same.
        }
    }
}
