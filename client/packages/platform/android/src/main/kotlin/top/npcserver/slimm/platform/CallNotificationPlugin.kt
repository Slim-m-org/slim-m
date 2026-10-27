// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

private const val CHANNEL_NAME = "top.npcserver.slimm/calls"

/**
 * The Dart-facing half of Android's incoming-call notification.
 *
 * Registered as a real Flutter plugin, not a bare [MethodChannel] wired up in
 * `MainActivity`, because `firebase_messaging`'s background isolate runs in
 * its own headless `FlutterEngine` that never sees `MainActivity` at all; a
 * plugin declared in `pubspec.yaml` is what Flutter's plugin loader attaches
 * to every engine it creates, that one included. See `call_notifications.dart`.
 */
class CallNotificationPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var notifier: IncomingCallNotifier
    private lateinit var appContext: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        appContext = binding.applicationContext
        notifier = IncomingCallNotifier(appContext)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "showIncomingCall" -> {
                val callId = call.argument<String>("callId")
                val callerName = call.argument<String>("callerName")
                if (callId == null || callerName == null) {
                    result.error("bad_args", "callId and callerName are required", null)
                    return
                }
                notifier.showIncomingCall(callId, callerName)
                result.success(null)
            }
            "endIncomingCalls" -> {
                notifier.endIncomingCalls()
                result.success(null)
            }
            "updateCallService" -> {
                CallForegroundService.update(
                    appContext,
                    call = call.argument<Boolean>("call") ?: false,
                    camera = call.argument<Boolean>("camera") ?: false,
                    share = call.argument<Boolean>("share") ?: false,
                )
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
