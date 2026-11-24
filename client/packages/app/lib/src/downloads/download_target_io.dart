// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Desktop saves straight into the Downloads folder; phones buffer for their own save flow.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'download_target.dart';
import 'safe_file_name.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const Duration _staleAfter = Duration(days: 1);

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

/// A file in [directory] for [filename] that nothing occupies, as
/// `name (2).ext` when the plain name is taken, so a save never overwrites.
/// The empty file is created exclusively, so concurrent saves get distinct names.
Future<File> freeDownloadFile(Directory directory, String filename) async {
  final name = safeFileName(filename, windows: Platform.isWindows);
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final extension = dot > 0 ? name.substring(dot) : '';
  for (var n = 1; ; n++) {
    final candidate = File(
      '${directory.path}${Platform.pathSeparator}'
      '${n == 1 ? name : '$stem ($n)$extension'}',
    );
    try {
      await candidate.create(exclusive: true);
      return candidate;
    } on FileSystemException {
      if (!await candidate.exists()) rethrow;
    }
  }
}

/// Writes to a private partial file and moves it over [chosen] only when
/// complete, so a failure or quit never leaves a truncated file under the real name.
class FileDownloadTarget implements DownloadTarget {
  FileDownloadTarget._(this._chosen, this._part, this._file);

  final File _chosen;
  final File _part;
  final RandomAccessFile _file;
  Future<void> _inFlight = Future<void>.value();
  bool _closed = false;

  /// Partials live in [partDirectory] (the app cache by default), never in Downloads.
  static Future<FileDownloadTarget> open(
    File chosen, {
    Directory? partDirectory,
  }) async {
    final directory = partDirectory ?? await _defaultPartDirectory(chosen);
    await directory.create(recursive: true);
    await _sweepStale(directory);
    final part = File('${directory.path}/${_partName()}');
    return FileDownloadTarget._(
      chosen,
      part,
      await part.open(mode: FileMode.write),
    );
  }

  static String _partName() {
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '$id.part';
  }

  static Future<Directory> _defaultPartDirectory(File chosen) async {
    try {
      final cache = await getApplicationCacheDirectory();
      return Directory('${cache.path}/downloads');
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'No app cache folder, keeping partial downloads beside the target',
        error,
        stack,
      );
      return Directory('${chosen.parent.path}/.slimm-partial');
    }
  }

  static Future<void> _sweepStale(Directory directory) async {
    final cutoff = DateTime.now().subtract(_staleAfter);
    try {
      await for (final entry in directory.list()) {
        if (entry is! File || !entry.path.endsWith('.part')) continue;
        if ((await entry.lastModified()).isBefore(cutoff)) await entry.delete();
      }
    } on FileSystemException catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Could not sweep old partial downloads',
        error,
        stack,
      );
    }
  }

  @override
  int? get maxBytes => null;

  @override
  Future<void> write(List<int> chunk) async {
    if (_closed) throw const FileSystemException('download was discarded');
    final pending = _file.writeFrom(chunk);
    _inFlight = pending.then<void>((_) {}, onError: (Object _) {});
    await pending;
  }

  @override
  Future<bool> finish() async {
    _closed = true;
    await _inFlight;
    await _file.close();
    await _moveIntoPlace();
    return true;
  }

  Future<void> _moveIntoPlace() async {
    try {
      await _part.rename(_chosen.path);
    } on FileSystemException {
      // Across file systems a rename cannot work, so copy and then drop the partial.
      await _part.copy(_chosen.path);
      await _part.delete();
    }
  }

  @override
  Future<void> discard() async {
    _closed = true;
    await _inFlight;
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
