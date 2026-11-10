// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.IntentCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future

/**
 * Receives what the system share sheet sends to slim-m (`ACTION_SEND` and
 * `ACTION_SEND_MULTIPLE`); the Dart half is `share_source.dart`, which owns
 * the channel name.
 *
 * A shared `content://` URI is readable only while the grant that came with
 * the intent lasts, so every file is copied into the app cache the moment the
 * intent arrives, off the main thread, and Dart is handed paths. [take]
 * answers once that copy has finished.
 */
class ShareIntakeChannel(private val context: Context) : MethodChannel.MethodCallHandler {
  private val copier: ExecutorService = Executors.newSingleThreadExecutor()
  private var channel: MethodChannel? = null
  private var pending: Future<Map<String, Any?>>? = null

  fun attach(messenger: BinaryMessenger) {
    channel = MethodChannel(messenger, NAME).also { it.setMethodCallHandler(this) }
  }

  /** Reads [intent] if it is a share and starts copying; [warm] tells Dart one arrived. */
  fun onIntent(intent: Intent?, warm: Boolean) {
    if (intent == null) return
    val action = intent.action
    if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
    val uris = sharedUris(intent)
    val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
    pending = copier.submit(Callable { copyAll(uris, text) })
    if (warm) channel?.invokeMethod("arrived", null)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "take" -> take(result)
      else -> result.notImplemented()
    }
  }

  /** Hands over the waiting share once, off the main thread so a large copy never blocks the UI. */
  private fun take(result: MethodChannel.Result) {
    val waiting = pending
    pending = null
    if (waiting == null) {
      result.success(null)
      return
    }
    val main = Handler(Looper.getMainLooper())
    Thread {
      try {
        val share = waiting.get()
        main.post { result.success(share) }
      } catch (e: Exception) {
        main.post { result.error("copy_failed", "The shared items could not be read.", null) }
      }
    }.start()
  }

  private fun sharedUris(intent: Intent): List<Uri> {
    val uris = LinkedHashSet<Uri>()
    IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)?.let { uris.add(it) }
    IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
      ?.let { uris.addAll(it) }
    val clip = intent.clipData
    if (uris.isEmpty() && clip != null) {
      for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
    }
    return uris.toList()
  }

  private fun copyAll(uris: List<Uri>, text: String?): Map<String, Any?> {
    val batch = File(context.cacheDir, "$INTAKE_DIR/${System.currentTimeMillis()}")
    purgeOldBatches(batch)
    val files = ArrayList<Map<String, Any?>>()
    var unreadable = 0
    for ((index, uri) in uris.withIndex()) {
      val copied = if (isUnsafeSource(uri)) null else copyOne(uri, File(batch, index.toString()))
      if (copied == null) unreadable++ else files.add(copied)
    }
    return mapOf("files" to files, "text" to text, "unreadable" to unreadable)
  }

  /**
   * A sender could name slim-m's own files; those are never something to attach.
   * `file://` is refused outright: it names a path, not a grant, so it could
   * point at this app's private data.
   */
  private fun isUnsafeSource(uri: Uri): Boolean =
    uri.scheme != "content" || uri.authority?.startsWith(context.packageName) == true

  private fun copyOne(uri: Uri, dir: File): Map<String, Any?>? {
    return try {
      val resolver = context.contentResolver
      val mimeType = resolver.getType(uri)
      val name = displayName(uri, mimeType)
      dir.mkdirs()
      val target = File(dir, name)
      val input = resolver.openInputStream(uri) ?: return null
      try {
        input.use { source -> target.outputStream().use { source.copyTo(it) } }
      } catch (e: Exception) {
        target.delete()
        throw e
      }
      mapOf("path" to target.path, "name" to name, "mimeType" to mimeType, "length" to target.length())
    } catch (e: Exception) {
      null
    }
  }

  private fun displayName(uri: Uri, mimeType: String?): String {
    var name: String? = null
    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
      if (it.moveToFirst()) name = it.getString(0)
    }
    val base = sanitize(name ?: uri.lastPathSegment ?: "shared")
    if (base.contains('.')) return base
    val extension = mimeType?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
    return if (extension == null) base else "$base.$extension"
  }

  /** Keeps a sender-chosen name from escaping its folder or overrunning the file system's limit. */
  private fun sanitize(raw: String): String {
    val cleaned = raw.substringAfterLast('/').replace(Regex("[\\u0000-\\u001f\\\\]"), "_").trim()
    val safe = if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") "shared" else cleaned
    return if (safe.length <= MAX_NAME) safe else safe.takeLast(MAX_NAME)
  }

  /** Earlier batches are only kept for staged files still waiting to send. */
  private fun purgeOldBatches(current: File) {
    val root = current.parentFile ?: return
    val cutoff = System.currentTimeMillis() - KEEP_MILLIS
    root.listFiles()?.filter { it != current && it.lastModified() < cutoff }
      ?.forEach { it.deleteRecursively() }
  }

  companion object {
    const val NAME = "top.npcserver.slimm/share_intake"
    private const val INTAKE_DIR = "shared_intake"
    private const val MAX_NAME = 120
    private const val KEEP_MILLIS = 24L * 60 * 60 * 1000
  }
}
