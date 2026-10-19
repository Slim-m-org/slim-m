// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Desktop saves straight into the Downloads folder; phones buffer for their own save flow.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'download_target.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

Future<DownloadTarget?> openPlatformDownloadTarget(String filename) async {
  if (!(Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
    return MemoryDownloadTarget(filename);
  }
  final downloads = await getDownloadsDirectory();
  if (downloads != null) {
    return FileDownloadTarget.open(await freeDownloadFile(downloads, filename));
  }
  // No Downloads folder: ask, and give the picker an empty list, which makes it claim the path.
  final saved = await FilePicker.saveFile(
    fileName: filename,
    bytes: Uint8List(0),
  );
  if (saved == null) return null;
  return FileDownloadTarget.open(File.fromUri(saved));
}

/// A path in [directory] for [filename] that nothing occupies yet, as
/// `name (2).ext` when the plain name is taken, so a save never overwrites.
Future<File> freeDownloadFile(Directory directory, String filename) async {
  final plain = filename.split(RegExp(r'[\\/]')).last;
  final name = plain.isEmpty || plain == '.' || plain == '..'
      ? 'download'
      : plain;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final extension = dot > 0 ? name.substring(dot) : '';
  for (var n = 1; ; n++) {
    final candidate = File(
      '${directory.path}${Platform.pathSeparator}'
      '${n == 1 ? name : '$stem ($n)$extension'}',
    );
    if (!await candidate.exists() &&
        !await File('${candidate.path}.part').exists()) {
      return candidate;
    }
  }
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
    } on FileSystemException catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Could not close the partly downloaded file before deleting it',
        error,
        stack,
      );
    }
    await _deleteQuietly(_part);
    // The picker's empty placeholder is ours to remove; a file with content is not.
    try {
      if (await _chosen.exists() && await _chosen.length() == 0) {
        await _chosen.delete();
      }
    } on FileSystemException catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'The empty download file was already gone',
        error,
        stack,
      );
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } on FileSystemException catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Could not delete a leftover download file',
        error,
        stack,
      );
      // Already gone.
    }
  }
}
