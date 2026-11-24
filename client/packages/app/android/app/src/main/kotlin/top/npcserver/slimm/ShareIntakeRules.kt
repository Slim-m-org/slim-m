// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import java.io.InputStream
import java.io.OutputStream

/** What the share intake accepts from a sender, free of Android types so it can run anywhere. */
internal object ShareIntakeRules {
  /** Kept under the 255 bytes a file system allows, since encrypted storage can pad a name. */
  const val MAX_NAME_BYTES = 200
  private const val MAX_EXTENSION_CHARS = 16

  /**
   * Whether [authority] names one of this app's own providers.
   *
   * The resolver reads a leading `userId@` as a user to address, so `0@pkg.files`
   * reaches the same provider as `pkg.files` and has to be treated the same.
   */
  fun namesOwnProvider(authority: String?, packageName: String): Boolean =
    authority?.substringAfterLast('@')?.startsWith(packageName, ignoreCase = true) == true

  /** One shared file past this is refused rather than copied; the server's own limit is checked later. */
  const val MAX_FILE_BYTES = 2L * 1024 * 1024 * 1024

  /** One share past this in total stops copying, so a batch cannot fill the cache. */
  const val MAX_SHARE_BYTES = 4L * 1024 * 1024 * 1024

  /** Free space that must stay after a copy, so a share cannot fill the phone. */
  const val FREE_SPACE_RESERVE = 256L * 1024 * 1024

  /** The folder of this app's provider that holds images copied by the composer. */
  const val OWN_CLIPBOARD_FOLDER = "clipboard_images"

  /**
   * Whether the clipboard may name this URI. Only `content://` is read, and this
   * app's own provider only for the folder the composer copies images into.
   */
  fun clipboardUriAllowed(
    scheme: String?,
    authority: String?,
    firstSegment: String?,
    packageName: String,
  ): Boolean {
    if (scheme != "content") return false
    if (!namesOwnProvider(authority, packageName)) return true
    return firstSegment == OWN_CLIPBOARD_FOLDER
  }

  /** How many more bytes one file may take: the per-file cap, what is left of the share, and free space. */
  fun allowedBytes(copiedSoFar: Long, freeSpace: Long): Long =
    minOf(MAX_FILE_BYTES, MAX_SHARE_BYTES - copiedSoFar, freeSpace - FREE_SPACE_RESERVE).coerceAtLeast(0)

  /** Copies [input] to [output]; false as soon as more than [limit] bytes would be written. */
  fun copyCapped(input: InputStream, output: OutputStream, limit: Long): Boolean {
    val buffer = ByteArray(64 * 1024)
    var total = 0L
    while (true) {
      val read = input.read(buffer)
      if (read < 0) return true
      total += read
      if (total > limit) return false
      output.write(buffer, 0, read)
    }
  }

  /** Folds shares that arrived before the first was taken into one, so none is dropped. */
  fun mergeShares(shares: List<Map<String, Any?>>): Map<String, Any?> {
    val files = shares.flatMap { (it["files"] as? List<*>).orEmpty() }
    val text = shares.mapNotNull { it["text"] as? String }.joinToString("\n").ifEmpty { null }
    return mapOf(
      "files" to files,
      "text" to text,
      "unreadable" to shares.sumOf { (it["unreadable"] as? Int) ?: 0 },
      "tooLarge" to shares.sumOf { (it["tooLarge"] as? Int) ?: 0 },
    )
  }

  /** Keeps a sender-chosen name from escaping its folder. */
  fun safeFileName(raw: String): String {
    val cleaned = raw.substringAfterLast('/').replace(Regex("[\\u0000-\\u001f\\\\]"), "_").trim()
    return if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") "shared" else cleaned
  }

  /** Shortens [name] to [MAX_NAME_BYTES] of UTF-8 by cutting its stem, keeping the extension and whole characters. */
  fun capNameBytes(name: String): String {
    if (utf8Size(name) <= MAX_NAME_BYTES) return name
    val dot = name.lastIndexOf('.')
    val extension = if (dot > 0 && name.length - dot <= MAX_EXTENSION_CHARS) name.substring(dot) else ""
    val stem = name.substring(0, name.length - extension.length)
    return takeBytes(stem, MAX_NAME_BYTES - utf8Size(extension)) + extension
  }

  private fun takeBytes(text: String, limit: Int): String {
    var bytes = 0
    var end = 0
    while (end < text.length) {
      val point = text.codePointAt(end)
      bytes += utf8Size(point)
      if (bytes > limit) break
      end += Character.charCount(point)
    }
    return text.substring(0, end)
  }

  private fun utf8Size(text: String): Int = text.toByteArray(Charsets.UTF_8).size

  private fun utf8Size(point: Int): Int =
    when {
      point < 0x80 -> 1
      point < 0x800 -> 2
      point < 0x10000 -> 3
      else -> 4
    }
}
