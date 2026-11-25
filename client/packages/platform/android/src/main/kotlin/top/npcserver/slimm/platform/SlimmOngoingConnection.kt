// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.net.Uri
import android.telecom.Connection
import android.telecom.DisconnectCause
import android.telecom.TelecomManager

/** The joined voice call as Telecom sees it, so a cellular or other VoIP call knows slim-m is busy. */
class SlimmOngoingConnection(val callId: String, displayName: String) : Connection() {
    init {
        setCallerDisplayName(displayName, TelecomManager.PRESENTATION_ALLOWED)
        setAddress(addressFor(callId), TelecomManager.PRESENTATION_ALLOWED)
        connectionProperties = PROPERTY_SELF_MANAGED
        connectionCapabilities = CAPABILITY_MUTE
        setAudioModeIsVoip(true)
        setDialing()
    }

    fun markConnected() = setActive()

    /** The app ended the call, so Telecom only needs telling. */
    fun endFromApp() {
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
    }

    /** The system ended it (another call took priority): the app has to leave the room. */
    override fun onDisconnect() {
        endFromApp()
        ActiveCall.endedBySystem(this)
    }

    override fun onAbort() = onDisconnect()

    companion object {
        private const val SCHEME = "slimm-call"

        fun addressFor(callId: String): Uri = Uri.fromParts(SCHEME, callId, null)

        fun callIdOf(address: Uri?): String? = address?.schemeSpecificPart?.takeIf { it.isNotEmpty() }
    }
}
