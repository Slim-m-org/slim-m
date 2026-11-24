// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The Android half of `PictureInPictureChannel` in `packages/platform`.
 *
 * Dart reports whether a call has video worth floating; this class turns that
 * into entering picture-in-picture when the user backs out of the app. Android
 * 12 and later enter on their own once auto-enter is set, earlier versions
 * enter from `onUserLeaveHint`, and the two never both run so the window is
 * not requested twice.
 */
class PictureInPictureBridge(private val activity: Activity) {
  private var channel: MethodChannel? = null
  private var eligible = false
  private var launchingOwnActivity = false

  private val supported: Boolean
    get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
      activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

  fun attach(messenger: BinaryMessenger) {
    val created = MethodChannel(messenger, NAME)
    created.setMethodCallHandler { call, result ->
      when (call.method) {
        "setEligible" -> {
          setEligible(call.arguments as? Boolean ?: false)
          result.success(null)
        }
        else -> result.notImplemented()
      }
    }
    channel = created
  }

  fun onUserLeaveHint() {
    if (launchingOwnActivity || !supported || !eligible || Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return
    if (activity.isInPictureInPictureMode) return
    activity.enterPictureInPictureMode(params())
  }

  /** The app itself is starting a picker, browser or installer, so the leave hint is not a Home press. */
  fun onOwnLaunch() {
    launchingOwnActivity = true
  }

  fun onResumed() {
    launchingOwnActivity = false
  }

  fun onModeChanged(inPictureInPicture: Boolean) {
    channel?.invokeMethod("modeChanged", inPictureInPicture)
  }

  private fun setEligible(value: Boolean) {
    eligible = value
    if (supported) activity.setPictureInPictureParams(params())
  }

  private fun params(): PictureInPictureParams {
    val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9))
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) builder.setAutoEnterEnabled(eligible)
    return builder.build()
  }

  companion object {
    const val NAME = "top.npcserver.slimm/picture_in_picture"
  }
}
