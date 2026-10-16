// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a download's bytes go as they arrive.
///
/// On desktop that is the file the user picked in the Save dialog, written
/// chunk by chunk so a multi-gigabyte attachment never sits in memory. Where
/// the platform's save flow only takes bytes (phones, web) it is a buffer
/// handed to that flow at the end.
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'download_target_web.dart'
    if (dart.library.io) 'download_target_io.dart'
    as platform;

abstract interface class DownloadTarget {
  Future<void> write(List<int> chunk);

  /// Commits what was written; returns once the user has it.
  Future<void> finish();

  /// Throws away whatever was written, including a partial file on disk.
  Future<void> discard();
}

/// Asks the user where to save [filename]; null when they dismiss the dialog.
typedef DownloadTargetOpener =
    Future<DownloadTarget?> Function(String filename);

Future<DownloadTarget?> openDownloadTarget(String filename) =>
    platform.openPlatformDownloadTarget(filename);

/// Buffers in memory, then gives the bytes to `file_picker`'s save flow.
class MemoryDownloadTarget implements DownloadTarget {
  MemoryDownloadTarget(this.filename);

  final String filename;
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  @override
  Future<void> write(List<int> chunk) async => _bytes.add(chunk);

  @override
  Future<void> finish() async {
    await FilePicker.saveFile(fileName: filename, bytes: _bytes.takeBytes());
  }

  @override
  Future<void> discard() async => _bytes.clear();
}
