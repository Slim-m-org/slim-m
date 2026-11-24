// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class ShareIntakeRulesTest {
  private val ownPackage = "top.npcserver.slimm"

  private fun bytes(text: String): Int = text.toByteArray(Charsets.UTF_8).size

  private fun hasNoLoneSurrogate(text: String): Boolean = Charsets.UTF_8.newEncoder().canEncode(text)

  private fun cjk(count: Int): String = "中".repeat(count)

  private fun fourByte(count: Int): String = String(Character.toChars(0x1F600)).repeat(count)

  @Test
  fun ownProviderIsRefused() {
    assertTrue(ShareIntakeRules.namesOwnProvider("$ownPackage.files", ownPackage))
  }

  @Test
  fun ownProviderWithAUserIdPrefixIsRefused() {
    assertTrue(ShareIntakeRules.namesOwnProvider("0@$ownPackage.files", ownPackage))
    assertTrue(ShareIntakeRules.namesOwnProvider("10@$ownPackage.files", ownPackage))
  }

  @Test
  fun ownProviderIsRefusedWhateverItsCase() {
    assertTrue(ShareIntakeRules.namesOwnProvider("TOP.NpcServer.Slimm.files", ownPackage))
  }

  @Test
  fun onlyTheLastUserIdPrefixDecidesTheProvider() {
    assertTrue(ShareIntakeRules.namesOwnProvider("1@0@$ownPackage.files", ownPackage))
    assertFalse(ShareIntakeRules.namesOwnProvider("$ownPackage@com.example.files", ownPackage))
  }

  @Test
  fun foreignProvidersAreAllowed() {
    assertFalse(ShareIntakeRules.namesOwnProvider("com.android.providers.media.documents", ownPackage))
    assertFalse(ShareIntakeRules.namesOwnProvider("0@com.google.android.apps.photos.contentprovider", ownPackage))
    assertFalse(ShareIntakeRules.namesOwnProvider("media", ownPackage))
  }

  @Test
  fun aMissingOrEmptyAuthorityNamesNoProvider() {
    assertFalse(ShareIntakeRules.namesOwnProvider(null, ownPackage))
    assertFalse(ShareIntakeRules.namesOwnProvider("", ownPackage))
    assertFalse(ShareIntakeRules.namesOwnProvider("0@", ownPackage))
  }

  @Test
  fun safeFileNameKeepsAnOrdinaryName() {
    assertEquals("holiday photo (1).jpg", ShareIntakeRules.safeFileName("holiday photo (1).jpg"))
  }

  @Test
  fun safeFileNameDropsEveryFolderBeforeTheName() {
    assertEquals("passwd", ShareIntakeRules.safeFileName("../../etc/passwd"))
    assertEquals("c.txt", ShareIntakeRules.safeFileName("/a/b/c.txt"))
  }

  @Test
  fun safeFileNameNeutralisesBackslashSeparators() {
    val cleaned = ShareIntakeRules.safeFileName("..\\..\\evil.txt")
    assertFalse(cleaned.contains('\\'))
    assertEquals(".._.._evil.txt", cleaned)
  }

  @Test
  fun safeFileNameReplacesControlCharacters() {
    assertEquals("a_b_c_d.txt", ShareIntakeRules.safeFileName("a\u0000b\nc\u001fd.txt"))
  }

  @Test
  fun safeFileNameTrimsSurroundingWhitespace() {
    assertEquals("photo.jpg", ShareIntakeRules.safeFileName("  photo.jpg "))
  }

  @Test
  fun safeFileNameFallsBackWhenNothingUsableIsLeft() {
    for (raw in listOf("", "   ", ".", "..", "folder/", "a/..", "a/.")) {
      assertEquals("shared for <$raw>", "shared", ShareIntakeRules.safeFileName(raw))
    }
  }

  @Test
  fun capNameBytesLeavesAShortNameAlone() {
    assertEquals("report.pdf", ShareIntakeRules.capNameBytes("report.pdf"))
  }

  @Test
  fun capNameBytesLeavesANameAtTheLimitAlone() {
    val atLimit = "a".repeat(ShareIntakeRules.MAX_NAME_BYTES - 4) + ".txt"
    assertEquals(ShareIntakeRules.MAX_NAME_BYTES, bytes(atLimit))
    assertEquals(atLimit, ShareIntakeRules.capNameBytes(atLimit))
  }

  @Test
  fun capNameBytesCutsAnAsciiStemAndKeepsTheExtension() {
    val capped = ShareIntakeRules.capNameBytes("a".repeat(300) + ".jpg")
    assertEquals("a".repeat(ShareIntakeRules.MAX_NAME_BYTES - 4) + ".jpg", capped)
  }

  @Test
  fun capNameBytesCountsUtf8BytesNotUtf16Units() {
    val capped = ShareIntakeRules.capNameBytes(cjk(85) + ".png")
    assertTrue("${bytes(capped)} bytes", bytes(capped) <= ShareIntakeRules.MAX_NAME_BYTES)
    assertEquals(cjk(65) + ".png", capped)
  }

  @Test
  fun capNameBytesNeverSplitsASurrogatePair() {
    val name = "a" + fourByte(60) + ".jpeg"
    val capped = ShareIntakeRules.capNameBytes(name)
    assertTrue(hasNoLoneSurrogate(capped))
    assertTrue("${bytes(capped)} bytes", bytes(capped) <= ShareIntakeRules.MAX_NAME_BYTES)
    assertEquals("a" + fourByte(48) + ".jpeg", capped)
  }

  @Test
  fun capNameBytesStopsBeforeACharacterThatWouldOverflow() {
    val capped = ShareIntakeRules.capNameBytes("a".repeat(199) + cjk(5))
    assertEquals("a".repeat(199), capped)
  }

  @Test
  fun capNameBytesCutsANameWithNoExtension() {
    val capped = ShareIntakeRules.capNameBytes("n".repeat(250))
    assertEquals("n".repeat(ShareIntakeRules.MAX_NAME_BYTES), capped)
  }

  @Test
  fun capNameBytesTreatsALeadingDotAsPartOfTheStem() {
    val capped = ShareIntakeRules.capNameBytes("." + "h".repeat(250))
    assertEquals("." + "h".repeat(ShareIntakeRules.MAX_NAME_BYTES - 1), capped)
  }

  @Test
  fun capNameBytesDoesNotProtectAnImplausiblyLongExtension() {
    val capped = ShareIntakeRules.capNameBytes("e".repeat(250) + "." + "x".repeat(20))
    assertEquals("e".repeat(ShareIntakeRules.MAX_NAME_BYTES), capped)
  }

  @Test
  fun clipboardRefusesEverySchemeButContent() {
    assertFalse(ShareIntakeRules.clipboardUriAllowed("file", null, "data", ownPackage))
    assertFalse(ShareIntakeRules.clipboardUriAllowed(null, "x", "a", ownPackage))
    assertTrue(ShareIntakeRules.clipboardUriAllowed("content", "com.example.provider", "a", ownPackage))
  }

  @Test
  fun clipboardRefusesOwnProviderOutsideItsClipboardFolder() {
    assertFalse(ShareIntakeRules.clipboardUriAllowed("content", "$ownPackage.files", "updates", ownPackage))
    assertFalse(ShareIntakeRules.clipboardUriAllowed("content", "0@$ownPackage.files", null, ownPackage))
    assertTrue(ShareIntakeRules.clipboardUriAllowed("content", "$ownPackage.files", "clipboard_images", ownPackage))
  }

  @Test
  fun copyCappedStopsPastTheLimit() {
    val out = ByteArrayOutputStream()
    assertFalse(ShareIntakeRules.copyCapped(ByteArrayInputStream(ByteArray(100)), out, 99))
    assertTrue(ShareIntakeRules.copyCapped(ByteArrayInputStream(ByteArray(100)), ByteArrayOutputStream(), 100))
  }

  @Test
  fun allowedBytesIsTheTightestOfTheCaps() {
    val gib = 1024L * 1024 * 1024
    assertEquals(ShareIntakeRules.MAX_FILE_BYTES, ShareIntakeRules.allowedBytes(0, 100 * gib))
    assertEquals(gib, ShareIntakeRules.allowedBytes(3 * gib, 100 * gib))
    assertEquals(0L, ShareIntakeRules.allowedBytes(0, 1024))
  }

  @Test
  fun mergedSharesKeepEveryFileAndCount() {
    val first = mapOf("files" to listOf("a"), "text" to "one", "unreadable" to 1, "tooLarge" to 0)
    val second = mapOf("files" to listOf("b"), "text" to null, "unreadable" to 0, "tooLarge" to 2)
    val merged = ShareIntakeRules.mergeShares(listOf(first, second))
    assertEquals(listOf("a", "b"), merged["files"])
    assertEquals("one", merged["text"])
    assertEquals(1, merged["unreadable"])
    assertEquals(2, merged["tooLarge"])
  }
}
