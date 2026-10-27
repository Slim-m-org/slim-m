// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.Manifest
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the process allowed to capture the microphone, the camera and the
 * screen while the app is in the background during a call.
 *
 * One service covers all three because a process may only have one
 * foreground notification per service; the declared types are recomputed
 * from [EXTRA_CALL], [EXTRA_CAMERA] and [EXTRA_SHARE] on every start, so a
 * camera toggle or a screen share changes the type without a second service.
 */
class CallForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val call = intent?.getBooleanExtra(EXTRA_CALL, false) ?: false
        val camera = intent?.getBooleanExtra(EXTRA_CAMERA, false) ?: false
        val share = intent?.getBooleanExtra(EXTRA_SHARE, false) ?: false
        if (!call && !share) {
            stopSelf()
            return START_NOT_STICKY
        }
        val entered = enterForeground(call, camera, share) ||
            (call && share && enterForeground(call, camera, false))
        if (!entered) stopSelf()
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
    }

    private fun enterForeground(call: Boolean, camera: Boolean, share: Boolean): Boolean {
        ensureChannel(this)
        val notification = buildNotification(call, share)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val type = resolveType(this, call, camera, share)
                if (type == 0) return false
                startForeground(NOTIFICATION_ID, notification, type)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (error: RuntimeException) {
            // Android 14 refuses a type whose permission or consent is missing, and any start from the background.
            Log.w(TAG, "Could not enter the foreground", error)
            false
        }
    }

    private fun buildNotification(call: Boolean, share: Boolean): Notification {
        val text = when {
            call && share -> "In a call, sharing your screen"
            share -> "Sharing your screen"
            else -> "In a voice call"
        }
        val openApp = PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            IncomingCallNotifier.openAppIntent(this),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(smallIcon(this))
            .setContentTitle("slim-m")
            .setContentText(text)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openApp)
            .build()
    }

    companion object {
        const val EXTRA_CALL = "call"
        const val EXTRA_CAMERA = "camera"
        const val EXTRA_SHARE = "share"
        const val CHANNEL_ID = "call_ongoing_v1"
        const val NOTIFICATION_ID = 0x51a1
        private const val TAG = "SlimmCallService"

        /**
         * The foreground service types this start may declare. A type is
         * dropped, not failed, when its runtime permission is not held,
         * because Android 14 throws on a declared type without its permission.
         */
        fun resolveType(context: Context, call: Boolean, camera: Boolean, share: Boolean): Int {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0
            var type = 0
            if (call && granted(context, Manifest.permission.RECORD_AUDIO)) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            if (call && camera && granted(context, Manifest.permission.CAMERA)) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
            if (share) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            return type
        }

        private fun granted(context: Context, permission: String): Boolean =
            ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

        fun ensureChannel(context: Context) {
            val channel = NotificationChannelCompat.Builder(
                CHANNEL_ID,
                NotificationManagerCompat.IMPORTANCE_LOW,
            )
                .setName("Ongoing call")
                .setDescription("Shown while you are in a call or sharing your screen.")
                .build()
            NotificationManagerCompat.from(context).createNotificationChannel(channel)
        }

        private fun smallIcon(context: Context): Int {
            val resId = context.resources.getIdentifier("ic_stat_notify", "drawable", context.packageName)
            return if (resId != 0) resId else context.applicationInfo.icon
        }

        fun update(context: Context, call: Boolean, camera: Boolean, share: Boolean) {
            val intent = Intent(context, CallForegroundService::class.java)
                .putExtra(EXTRA_CALL, call)
                .putExtra(EXTRA_CAMERA, camera)
                .putExtra(EXTRA_SHARE, share)
            if (!call && !share) {
                context.stopService(intent)
            } else {
                ContextCompat.startForegroundService(context, intent)
            }
        }
    }
}
