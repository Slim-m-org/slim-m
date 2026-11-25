// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
package top.npcserver.slimm

import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Saves a finished download from the app cache through the system "create document" dialog, so a
 * large file crosses to the document provider in small blocks and never as one array on the channel.
 * The Dart half is `phone_file_saver.dart`, which owns the channel name.
 *
 * Must be constructed while [activity] is being created, because the picker is registered with it.
 */
class FileExportChannel(private val activity: ComponentActivity) : MethodChannel.MethodCallHandler {
  companion object {
    const val NAME = "top.npcserver.slimm/file_export"
    const val BLOCK_BYTES = 64 * 1024

    private val copier = Executors.newSingleThreadExecutor()
  }

  private class Pending(val source: File, val result: MethodChannel.Result)

  private val mainThread = Handler(Looper.getMainLooper())
  private var pending: Pending? = null

  private val picker = activity.registerForActivityResult(
    ActivityResultContracts.CreateDocument("application/octet-stream"),
  ) { document -> onPicked(document) }

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, NAME).setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method != "saveCopy") return result.notImplemented()
    val path = call.argument<String>("path")
    val fileName = call.argument<String>("fileName")
    if (path == null || fileName == null) {
      return result.error("bad_arguments", "path and fileName are required", null)
    }
    if (pending != null) return result.error("busy", "a save dialog is already open", null)
    pending = Pending(File(path), result)
    picker.launch(fileName)
  }

  private fun onPicked(document: Uri?) {
    val saving = pending ?: return
    pending = null
    if (document == null) return saving.result.success(false)
    copier.execute {
      val failure = copy(saving.source, document)
      mainThread.post {
        if (failure == null) saving.result.success(true) else saving.result.error("copy_failed", failure, null)
      }
    }
  }

  /** Null on success; otherwise why it failed, with the empty document removed again. */
  private fun copy(source: File, document: Uri): String? {
    return try {
      val output = activity.contentResolver.openOutputStream(document, "wt")
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
      DocumentsContract.deleteDocument(activity.contentResolver, document)
    } catch (_: Exception) {
      // The provider may already have removed it, or not allow deleting.
    }
  }
}
