package top.npcserver.slimm

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * `FlutterFragmentActivity`, not the template's `FlutterActivity`: the
 * biometric app lock's `local_auth_android` implementation shows Android's
 * `BiometricPrompt`, which needs a `FragmentActivity` to attach a
 * `DialogFragment` to and throws at call time against a plain `Activity`.
 */
class MainActivity : FlutterFragmentActivity() {
    private val pictureInPicture = PictureInPictureBridge(this)

    /**
     * Locks phones to portrait and leaves tablets alone.
     *
     * The decision comes from `R.bool.slimm_portrait_only`, which the
     * values-sw600dp override flips to false, because sw600dp is Android's
     * own phone/tablet line and it is resolved against the live device
     * configuration here. It could not be `android:screenOrientation` in the
     * manifest: that attribute is read while parsing the package with the
     * default configuration, so the qualified resource would never be picked
     * and every tablet would be locked as well.
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestedOrientation = if (resources.getBoolean(R.bool.slimm_portrait_only)) {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        } else {
            ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ClipboardImageChannel(applicationContext).attach(flutterEngine.dartExecutor.binaryMessenger)
        pictureInPicture.attach(flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_LOCK_WINDOW_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setPrivacyShield" -> {
                        setPrivacyShield(call.arguments as? Boolean ?: false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ORIENTATION_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "allowLandscape" -> result.success(allowLandscape(call.arguments as? Boolean ?: false))
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Lets a portrait-locked phone rotate while a call's video is full screen
     * (decision 0058), and locks it again after. A tablet is never locked, so
     * it reports false and nothing changes; see `OrientationChannel` in
     * `packages/platform`.
     */
    private fun allowLandscape(allowed: Boolean): Boolean {
        if (!resources.getBoolean(R.bool.slimm_portrait_only)) return false
        requestedOrientation = if (allowed) {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR
        } else {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        return true
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        pictureInPicture.onUserLeaveHint()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pictureInPicture.onModeChanged(isInPictureInPictureMode)
    }

    /**
     * The Android half of the app lock's privacy shield (see
     * `AppLockWindowChannel` in `packages/platform`, and `SceneDelegate.swift`
     * for the iOS half). `FLAG_SECURE` blocks a screenshot or a screen
     * recording of slim-m's content and blanks its thumbnail in the
     * recent-apps switcher, in one call. Off by default; Dart sets this once
     * the app-lock preference restores, and again on every toggle.
     */
    private fun setPrivacyShield(enabled: Boolean) {
        if (enabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    companion object {
        private const val APP_LOCK_WINDOW_CHANNEL = "top.npcserver.slimm/app_lock_window"
        private const val ORIENTATION_CHANNEL = "top.npcserver.slimm/orientation"
    }
}
