// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Desktop saves straight to the picked path; phones buffer for their own save flow.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'download_target.dart';

Future<DownloadTarget?> openPlatformDownloadTarget(String filename) async {
  if (!(Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
    return MemoryDownloadTarget(filename);
  }
  // Desktop pickers write the bytes they are given to the chosen path; an empty list claims it.
  final saved = await FilePicker.saveFile(
    fileName: filename,
    bytes: Uint8List(0),
  );
  if (saved == null) return null;
  return FileDownloadTarget.open(File.fromUri(saved));
}

/// Writes to `<chosen>.part` and renames over [chosen] only when complete, so
/// a failure or quit never leaves a truncated file under the real name.
class FileDownloadTarget implements DownloadTarget {
  FileDownloadTarget._(this._chosen, this._part, this._file);

  final File _chosen;
  final File _part;
  final RandomAccessFile _file;
  bool _closed = false;

  static Future<FileDownloadTarget> open(File chosen) async {
    final part = File('${chosen.path}.part');
    return FileDownloadTarget._(
      chosen,
      part,
      await part.open(mode: FileMode.write),
    );
  }

  @override
  int? get maxBytes => null;

  @override
  Future<void> write(List<int> chunk) async {
    if (_closed) throw const FileSystemException('download was discarded');
    await _file.writeFrom(chunk);
  }

  @override
  Future<bool> finish() async {
    _closed = true;
    await _file.close();
    await _part.rename(_chosen.path);
    return true;
  }

  @override
  Future<void> discard() async {
    _closed = true;
    try {
      await _file.close();
    } on FileSystemException {
      // A close that fails must not stop the cleanup below.
    }
    await _deleteQuietly(_part);
    // The picker's empty placeholder is ours to remove; a file with content is not.
    try {
      if (await _chosen.exists() && await _chosen.length() == 0) {
        await _chosen.delete();
      }
    } on FileSystemException {
      // Already gone or unreadable.
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}
