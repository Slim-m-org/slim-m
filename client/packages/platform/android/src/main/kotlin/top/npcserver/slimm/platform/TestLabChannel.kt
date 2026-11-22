// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.content.Context
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

private const val CHANNEL_NAME = "top.npcserver.slimm/test_lab"

/** Answers whether Firebase Test Lab marked this device; see `test_lab_channel.dart`. */
class TestLabChannel(context: Context, messenger: BinaryMessenger) {
    private val resolver = context.contentResolver
    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isTestLab" -> result.success(Settings.System.getString(resolver, "firebase.test.lab") == "true")
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() = channel.setMethodCallHandler(null)
}
