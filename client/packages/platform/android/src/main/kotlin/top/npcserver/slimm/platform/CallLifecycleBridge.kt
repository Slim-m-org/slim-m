// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

private const val CHANNEL_NAME = "top.npcserver.slimm/call_lifecycle"

/** The Android end of `CallLifecycleChannel`: reports the joined call to Telecom and hears when the system ends it. */
class CallLifecycleBridge(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    init {
        bridges.add(this)
        channel.setMethodCallHandler { call, result ->
            val id = call.argument<String>("callId")
            when (call.method) {
                "callStarted" ->
                    if (id != null) {
                        ActiveCall.start(context, id, call.argument<String>("displayName").orEmpty())
                    }
                "callConnected" -> if (id != null) ActiveCall.connected(id)
                "callEnded" -> if (id != null) ActiveCall.end(id)
                else -> {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
            }
            result.success(null)
        }
    }

    fun dispose() {
        bridges.remove(this)
        channel.setMethodCallHandler(null)
    }

    companion object {
        private val bridges = mutableSetOf<CallLifecycleBridge>()
        private val main = Handler(Looper.getMainLooper())

        /** Tells every engine's Dart side to leave the room; an engine with no listener ignores it. */
        fun requestEnd() {
            main.post { bridges.toList().forEach { it.channel.invokeMethod("endCall", null) } }
        }
    }
}
