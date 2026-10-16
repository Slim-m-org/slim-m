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

  /// Largest download this target can hold, or null for no limit.
  int? get maxBytes;

  /// Commits what was written; true once the user has it, false when they
  /// dismissed the final save step.
  Future<bool> finish();

  /// Throws away whatever was written, including a partial file on disk.
  Future<void> discard();
}

/// Asks the user where to save [filename]; null when they dismiss the dialog.
typedef DownloadTargetOpener =
    Future<DownloadTarget?> Function(String filename);

Future<DownloadTarget?> openDownloadTarget(String filename) =>
    platform.openPlatformDownloadTarget(filename);

/// The most a memory-buffered target takes before refusing; phones and the
/// browser would otherwise run out of memory on a multi-gigabyte file.
const int kMemoryDownloadLimit = 256 * 1024 * 1024;

/// Buffers in memory, then gives the bytes to `file_picker`'s save flow,
/// which on Android, iOS and web only accepts bytes.
class MemoryDownloadTarget implements DownloadTarget {
  MemoryDownloadTarget(this.filename);

  final String filename;
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  @override
  int? get maxBytes => kMemoryDownloadLimit;

  @override
  Future<void> write(List<int> chunk) async {
    if (_bytes.length + chunk.length > kMemoryDownloadLimit) {
      throw StateError('download too large to buffer');
    }
    _bytes.add(chunk);
  }

  @override
  Future<bool> finish() async {
    final saved = await FilePicker.saveFile(
      fileName: filename,
      bytes: _bytes.takeBytes(),
    );
    return saved != null;
  }

  @override
  Future<void> discard() async => _bytes.clear();
}
