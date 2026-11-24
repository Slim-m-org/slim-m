// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import android.content.pm.ActivityInfo

/** Window decisions free of Activity state, so they can be tested on the JVM. */
internal object WindowRules {
  /** The requested orientation for the current width class; a full-screen video may rotate a phone. */
  fun orientation(portraitOnly: Boolean, videoFullscreen: Boolean): Int = when {
    !portraitOnly -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    videoFullscreen -> ActivityInfo.SCREEN_ORIENTATION_SENSOR
    else -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
  }
}
