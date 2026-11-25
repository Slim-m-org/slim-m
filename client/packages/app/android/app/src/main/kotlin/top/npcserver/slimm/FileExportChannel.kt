// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Copies a finished download from the app cache into a document the user picked, so a large
 * file crosses to the document provider in small blocks and never as one array on the channel.
 * The Dart half is `phone_file_saver.dart`, which owns the channel name.
 */
class FileExportChannel(private val context: Context) : MethodChannel.MethodCallHandler {
  companion object {
    const val NAME = "top.npcserver.slimm/file_export"

    const val BLOCK_BYTES = 64 * 1024

    private val copier = Executors.newSingleThreadExecutor()
  }

  private val mainThread = Handler(Looper.getMainLooper())

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, NAME).setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method != "copyToDocument") return result.notImplemented()
    val path = call.argument<String>("path")
    val document = call.argument<String>("document")
    if (path == null || document == null) {
      return result.error("bad_arguments", "path and document are required", null)
    }
    copier.execute {
      val failure = copy(File(path), Uri.parse(document))
      mainThread.post {
        if (failure == null) result.success(null) else result.error("copy_failed", failure, null)
      }
    }
  }

  /** Null on success; otherwise why it failed, with the empty document removed again. */
  private fun copy(source: File, document: Uri): String? {
    return try {
      val output = context.contentResolver.openOutputStream(document, "wt")
        ?: throw IOException("the document could not be opened")
      output.use { out -> source.inputStream().use { it.copyTo(out, BLOCK_BYTES) } }
      null
    } catch (error: IOException) {
      discard(document)
      error.message ?: "the copy failed"
    } catch (error: SecurityException) {
      discard(document)
      error.message ?: "the document is not writable"
    }
  }

  private fun discard(document: Uri) {
    try {
      DocumentsContract.deleteDocument(context.contentResolver, document)
    } catch (_: Exception) {
      // The provider may already have removed it, or not allow deleting.
    }
  }
}
