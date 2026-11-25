// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import top.npcserver.slimm.platform.ActiveCall

class ActiveCallRulesTest {
  @Test
  fun onlyADirectCallIsReportedToTelecom() {
    assertTrue(ActiveCall.reportsToTelecom(true))
    assertFalse(ActiveCall.reportsToTelecom(false))
    assertFalse(ActiveCall.reportsToTelecom(null))
  }
}
