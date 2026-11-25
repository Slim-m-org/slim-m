// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Asks for `BLUETOOTH_CONNECT`, the runtime grant Android 12+ requires before
 * the call audio switcher may list or route to a Bluetooth headset. Older
 * releases grant the manifest permission at install, so they answer true.
 */
class BluetoothPermissionChannel(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "request" -> request(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun granted() = ContextCompat.checkSelfPermission(
        activity, Manifest.permission.BLUETOOTH_CONNECT,
    ) == PackageManager.PERMISSION_GRANTED

    private fun request(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || granted()) {
            result.success(true)
            return
        }
        pending?.success(false)
        pending = result
        ActivityCompat.requestPermissions(
            activity, arrayOf(Manifest.permission.BLUETOOTH_CONNECT), REQUEST_CODE,
        )
    }

    /** Returns whether [requestCode] was this channel's, so the activity can leave other requests to plugins. */
    fun onResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        pending?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        pending = null
        return true
    }

    companion object {
        private const val CHANNEL = "top.npcserver.slimm/bluetooth_permission"
        private const val REQUEST_CODE = 0x0B1E
    }
}
