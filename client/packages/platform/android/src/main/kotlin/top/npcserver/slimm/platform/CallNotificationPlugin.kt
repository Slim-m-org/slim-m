// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry

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
class CallNotificationPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private lateinit var notifier: IncomingCallNotifier
    private lateinit var appContext: Context
    private var testLab: TestLabChannel? = null
    private var callKit: CallKitBridge? = null
    private var lifecycle: CallLifecycleBridge? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val newIntents = PluginRegistry.NewIntentListener { intent ->
        consumeAnswer(intent)
        false
    }

    /** Whether this engine's last word was that a call or share is live; see [onDetachedFromEngine]. */
    private var ownsCallService = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        appContext = binding.applicationContext
        notifier = IncomingCallNotifier(appContext)
        testLab = TestLabChannel(appContext, binding.binaryMessenger)
        callKit = CallKitBridge(appContext, binding.binaryMessenger)
        lifecycle = CallLifecycleBridge(appContext, binding.binaryMessenger)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attach(binding)

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attach(binding)

    override fun onDetachedFromActivityForConfigChanges() = detach()

    override fun onDetachedFromActivity() = detach()

    private fun attach(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(newIntents)
        consumeAnswer(binding.activity.intent)
    }

    private fun detach() {
        val binding = activityBinding ?: return
        binding.removeOnNewIntentListener(newIntents)
        activityBinding = null
    }

    /** The extra is removed once read, so a recreated activity does not answer the same ring twice. */
    private fun consumeAnswer(intent: Intent?) {
        val callId = intent?.getStringExtra(IncomingCallNotifier.EXTRA_ANSWERED_CALL_ID) ?: return
        intent.removeExtra(IncomingCallNotifier.EXTRA_ANSWERED_CALL_ID)
        if (!AnswerIntentRules.mayAnswer(intent.flags)) return
        IncomingRings.answered(appContext, callId)
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
                val inCall = call.argument<Boolean>("call") ?: false
                val sharing = call.argument<Boolean>("share") ?: false
                val started = CallForegroundService.update(
                    appContext,
                    call = inCall,
                    camera = call.argument<Boolean>("camera") ?: false,
                    share = sharing,
                )
                ownsCallService = started && (inCall || sharing)
                result.success(started)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * An engine that started the call service and is now going away can never
     * stop it, so the call notification would outlive the call. Only the
     * engine that started it stops it: the push isolate's engine also gets
     * this plugin and detaches on its own schedule.
     */
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        testLab?.dispose()
        testLab = null
        callKit?.dispose()
        callKit = null
        lifecycle?.dispose()
        lifecycle = null
        if (ownsCallService) {
            CallForegroundService.update(appContext, call = false, camera = false, share = false)
            ownsCallService = false
        }
    }
}
