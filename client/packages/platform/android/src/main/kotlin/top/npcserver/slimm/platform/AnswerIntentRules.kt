// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm.platform

import android.content.Intent

/** Which launches of the app may carry an answer. */
object AnswerIntentRules {
    /**
     * Opening the app from recents hands back the intent the task started with, extras and all, so
     * an answer read from it would answer a ring that ended long ago.
     */
    fun mayAnswer(flags: Int): Boolean = flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY == 0
}
