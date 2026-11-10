// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

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
