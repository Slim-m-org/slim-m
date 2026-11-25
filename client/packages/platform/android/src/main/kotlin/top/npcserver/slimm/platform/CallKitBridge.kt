// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

private const val CHANNEL_NAME = "top.npcserver.slimm/callkit_incoming"

/** The Android end of `CallKitIncomingChannel`: the same events iOS sends, from the notification and Telecom. */
class CallKitBridge(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePending" ->
                    result.success(CallEvents.takePending(context, this).map { it.toMap() })
                "endCall" -> {
                    endRing(call.argument<String>("id"))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun send(event: CallEvent) {
        main.post { channel.invokeMethod("onCallKitEvent", event.toMap()) }
    }

    fun dispose() {
        CallEvents.release(this)
        channel.setMethodCallHandler(null)
    }

    private fun endRing(callId: String?) {
        if (callId == null) return
        SlimmConnection.registry[callId]?.endAsMissed()
        NotificationManagerCompat.from(context).cancel(IncomingCallNotifier.notificationIdFor(callId))
        IncomingRings.finish(callId)
    }
}
