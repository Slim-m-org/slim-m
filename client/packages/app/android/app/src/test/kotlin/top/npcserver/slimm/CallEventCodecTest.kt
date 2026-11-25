// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import org.junit.Assert.assertEquals
import org.junit.Test
import top.npcserver.slimm.platform.CallEvent
import top.npcserver.slimm.platform.CallEventCodec

class CallEventCodecTest {
  @Test
  fun heldEventsComeBackInOrder() {
    val held = listOf(CallEvent("answered", "ring-1", 100L), CallEvent("declined", "ring-2", 200L))

    assertEquals(held, CallEventCodec.decode(CallEventCodec.encode(held)))
  }

  @Test
  fun nothingHeldDecodesToNothing() {
    assertEquals(emptyList<CallEvent>(), CallEventCodec.decode(null))
    assertEquals(emptyList<CallEvent>(), CallEventCodec.decode(""))
  }

  @Test
  fun aSeparatorInsideAnIdCannotSplitOrForgeAnEvent() {
    val decoded = CallEventCodec.decode(CallEventCodec.encode(listOf(CallEvent("declined", "a\nanswered\tb", 5L))))

    assertEquals(listOf(CallEvent("declined", "a answered b", 5L)), decoded)
  }

  @Test
  fun damagedRowsAreDropped() {
    assertEquals(
      listOf(CallEvent("declined", "ring-1", 7L)),
      CallEventCodec.decode("garbage\ndeclined\tring-1\t7\n\t\t1\nonly\t"),
    )
  }

  @Test
  fun anAppThatNeverOpensKeepsOnlyTheNewestEvents() {
    val many = (1..20).map { CallEvent("declined", "ring-$it") }

    assertEquals(many.takeLast(16), CallEventCodec.capped(many, 16))
  }

  @Test
  fun anEventOlderThanARingLastsIsNotReplayed() {
    val held = listOf(
      CallEvent("answered", "old", 1_000L),
      CallEvent("answered", "new", 90_000L),
      CallEvent("declined", "untimed"),
    )

    assertEquals(listOf(CallEvent("answered", "new", 90_000L)), CallEventCodec.fresh(held, 100_000L, 30_000L))
  }

  @Test
  fun heldEventsAreToldToDartAsRingIds() {
    assertEquals(true, CallEvent("answered", "ring-1").toMap()["ring_id"])
  }
}
