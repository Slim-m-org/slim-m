// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import android.content.Intent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import top.npcserver.slimm.platform.AnswerIntentRules

class AnswerIntentRulesTest {
  @Test
  fun aFreshLaunchMayAnswer() {
    assertTrue(AnswerIntentRules.mayAnswer(Intent.FLAG_ACTIVITY_NEW_TASK))
  }

  @Test
  fun aLaunchFromRecentsNeverAnswers() {
    assertFalse(
      AnswerIntentRules.mayAnswer(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY),
    )
  }
}
