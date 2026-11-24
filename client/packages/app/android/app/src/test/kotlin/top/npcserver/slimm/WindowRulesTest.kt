// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import android.content.pm.ActivityInfo
import org.junit.Assert.assertEquals
import org.junit.Test

class WindowRulesTest {
  @Test
  fun phoneWidthIsLockedToPortrait() {
    assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, WindowRules.orientation(portraitOnly = true, videoFullscreen = false))
  }

  @Test
  fun tabletWidthIsReleasedEvenAfterAPhoneLaunch() {
    assertEquals(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED, WindowRules.orientation(portraitOnly = false, videoFullscreen = false))
  }

  @Test
  fun fullscreenVideoRotatesAPhoneButNeverLocksATablet() {
    assertEquals(ActivityInfo.SCREEN_ORIENTATION_SENSOR, WindowRules.orientation(portraitOnly = true, videoFullscreen = true))
    assertEquals(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED, WindowRules.orientation(portraitOnly = false, videoFullscreen = true))
  }
}
