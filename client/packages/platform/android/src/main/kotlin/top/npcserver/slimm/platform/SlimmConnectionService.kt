// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccountHandle

/**
 * The self-managed `android.telecom.ConnectionService` [IncomingCallNotifier]
 * reports every incoming call push to, registered in `AndroidManifest.xml`
 * alongside the `BIND_TELECOM_CONNECTION_SERVICE` permission Telecom
 * requires of the component it binds to.
 *
 * Self-managed rather than a managed (default-dialer) connection service:
 * this app is not, and does not want to be, the phone dialer, and a self-
 * managed connection needs only the normal `MANAGE_OWN_CALLS` permission
 * (granted at install, no runtime prompt) rather than that much broader
 * role. See [SlimmConnection]'s own doc for what this integration does and
 * deliberately does not attempt.
 */
class SlimmConnectionService : ConnectionService() {
    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest,
    ): Connection {
        val extras = request.extras
        val callId = extras?.getString(SlimmConnection.EXTRA_CALL_ID).orEmpty()
        val callerName = extras?.getString(SlimmConnection.EXTRA_CALLER_NAME).orEmpty()
        SlimmConnection.registry.remove(callId)?.endReplaced()
        val connection = SlimmConnection(applicationContext, callId, callerName)
        connection.setRinging()
        SlimmConnection.registry[callId] = connection
        return connection
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest,
    ): Connection {
        val callId = SlimmOngoingConnection.callIdOf(request.address).orEmpty()
        val displayName = request.extras?.getString(SlimmConnection.EXTRA_CALLER_NAME).orEmpty()
        val connection = SlimmOngoingConnection(callId, displayName)
        ActiveCall.connectionCreated(connection)
        return connection
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        // Telecom refused the call; the app's own call carries on without a Telecom entry.
        ActiveCall.end(SlimmOngoingConnection.callIdOf(request?.address))
    }

    /** Telecom passes null here, so a non-null parameter crashes the process on a refused call. */
    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        // Telecom refused the call (no free slot, the account not yet
        // enabled by the user, ...); the notification IncomingCallNotifier
        // already posted is the only surface left, so there is nothing
        // further to do here.
    }
}
