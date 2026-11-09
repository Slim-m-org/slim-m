// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hands an update apk the Dart side already verified against the signed
 * manifest to Android's installer. Android then refuses it unless it is
 * signed by the same key as the installed app, and the user confirms.
 */
class ApkInstallChannel(private val activity: Activity) {
    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "install" -> result.success(install(File(call.arguments as String)))
                else -> result.notImplemented()
            }
        }
    }

    /** "needs_permission" when Android first has to let slim-m install apps. */
    private fun install(apk: File): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}"),
                ),
            )
            return "needs_permission"
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.files", apk)
        activity.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, APK_MIME_TYPE)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
        )
        return "started"
    }

    companion object {
        private const val CHANNEL = "top.npcserver.slimm/apk_install"
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }
}
