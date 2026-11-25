// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The ring screen shown over the lock screen: caller, Answer and Decline, and nothing of the app.
 *
 * Answering asks the keyguard to dismiss first, so the app opens only once the phone is unlocked.
 * It closes with its ring, and never shows for one that is not live in this process.
 */
class IncomingCallActivity : Activity() {
    private var stopWatching: (() -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val callId = intent.getStringExtra(EXTRA_CALL_ID)
        if (callId == null || !IncomingRings.isLive(callId)) {
            finish()
            return
        }
        allowOverLockScreen()
        stopWatching = IncomingRings.watch(callId) { finish() }
        setContentView(content(callId, intent.getStringExtra(EXTRA_CALLER_NAME).orEmpty()))
    }

    override fun onDestroy() {
        stopWatching?.invoke()
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun allowOverLockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
    }

    private fun answer(callId: String) {
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !keyguard.isKeyguardLocked) {
            openApp(callId)
            return
        }
        keyguard.requestDismissKeyguard(
            this,
            object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() = openApp(callId)
            },
        )
    }

    private fun openApp(callId: String) {
        startActivity(IncomingCallNotifier.answerIntent(this, callId))
        finish()
    }

    private fun decline(callId: String) {
        IncomingRings.declined(this, callId)
        finish()
    }

    private fun content(callId: String, callerName: String) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        setBackgroundColor(BACKGROUND)
        setPadding(dp(24), dp(24), dp(24), dp(24))
        addView(label(callerName, 28f, Typeface.BOLD, Color.WHITE))
        addView(label(applicationInfo.loadLabel(packageManager).toString(), 16f, Typeface.NORMAL, MUTED))
        val actions = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(48), 0, 0)
            addView(actionButton("Decline", DECLINE) { decline(callId) })
            addView(actionButton("Answer", ANSWER) { answer(callId) })
        }
        addView(actions)
    }

    private fun label(text: String, sp: Float, style: Int, color: Int) = TextView(this).apply {
        this.text = text
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        setTypeface(null, style)
        setTextColor(color)
        gravity = Gravity.CENTER
        setPadding(0, dp(4), 0, dp(4))
    }

    private fun actionButton(text: String, fill: Int, onClick: () -> Unit) = Button(this).apply {
        this.text = text
        isAllCaps = false
        setTextColor(Color.WHITE)
        background = GradientDrawable().apply {
            setColor(fill)
            cornerRadius = dp(28).toFloat()
        }
        minimumWidth = dp(128)
        minimumHeight = dp(56)
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            .apply { setMargins(dp(12), 0, dp(12), 0) }
        setOnClickListener { onClick() }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val EXTRA_CALL_ID = "top.npcserver.slimm.extra.RING_CALL_ID"
        private const val EXTRA_CALLER_NAME = "top.npcserver.slimm.extra.RING_CALLER_NAME"
        private const val BACKGROUND = 0xFF111214.toInt()
        private const val MUTED = 0xFFA0A4AB.toInt()
        private const val ANSWER = 0xFF2E9E5B.toInt()
        private const val DECLINE = 0xFFD64545.toInt()

        fun intent(context: Context, callId: String, callerName: String): Intent =
            Intent(context, IncomingCallActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION)
                .putExtra(EXTRA_CALL_ID, callId)
                .putExtra(EXTRA_CALLER_NAME, callerName)
    }
}
