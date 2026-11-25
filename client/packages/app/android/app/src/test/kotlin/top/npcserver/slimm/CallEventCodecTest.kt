// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import org.junit.Assert.assertEquals
import org.junit.Test
import top.npcserver.slimm.platform.CallEvent
import top.npcserver.slimm.platform.CallEventCodec

class CallEventCodecTest {
  @Test
  fun heldEventsComeBackInOrder() {
    val held = listOf(CallEvent("answered", "ring-1"), CallEvent("declined", "ring-2"))

    assertEquals(held, CallEventCodec.decode(CallEventCodec.encode(held)))
  }

  @Test
  fun nothingHeldDecodesToNothing() {
    assertEquals(emptyList<CallEvent>(), CallEventCodec.decode(null))
    assertEquals(emptyList<CallEvent>(), CallEventCodec.decode(""))
  }

  @Test
  fun aSeparatorInsideAnIdCannotSplitOrForgeAnEvent() {
    val decoded = CallEventCodec.decode(CallEventCodec.encode(listOf(CallEvent("declined", "a\nanswered\tb"))))

    assertEquals(listOf(CallEvent("declined", "a answered b")), decoded)
  }

  @Test
  fun damagedRowsAreDropped() {
    assertEquals(listOf(CallEvent("declined", "ring-1")), CallEventCodec.decode("garbage\ndeclined\tring-1\n\t\nonly\t"))
  }

  @Test
  fun anAppThatNeverOpensKeepsOnlyTheNewestEvents() {
    val many = (1..20).map { CallEvent("declined", "ring-$it") }

    assertEquals(many.takeLast(16), CallEventCodec.capped(many, 16))
  }
}
