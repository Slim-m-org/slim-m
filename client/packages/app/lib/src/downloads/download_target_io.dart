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
  final file = await File.fromUri(saved).open(mode: FileMode.write);
  return _FileTarget(file, saved);
}

class _FileTarget implements DownloadTarget {
  _FileTarget(this._file, this._uri);

  final RandomAccessFile _file;
  final Uri _uri;

  @override
  Future<void> write(List<int> chunk) async {
    await _file.writeFrom(chunk);
  }

  @override
  Future<void> finish() async {
    await _file.close();
  }

  @override
  Future<void> discard() async {
    try {
      await _file.close();
      await File.fromUri(_uri).delete();
    } on FileSystemException {
      // Already gone or unwritable; there is nothing further to clean up.
    }
  }
}
