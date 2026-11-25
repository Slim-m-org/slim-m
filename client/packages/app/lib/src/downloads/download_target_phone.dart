// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Phone saves: the download streams into the app cache, then the finished file goes to the platform's save step.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'download_target.dart';
import 'download_target_io.dart';
import 'safe_file_name.dart';

/// Hands a finished file to the platform's save or share step; true once the user has it.
typedef PhoneFileSaver = Future<bool> Function(File file, String filename);

const Duration _staleAfter = Duration(days: 1);
const String _handoffFolder = 'phone-saves';

/// Writes to a file in the app cache, so the bytes never sit in memory at once, and
/// gives that file to [PhoneFileSaver] when the transfer is complete.
class PhoneDownloadTarget implements DownloadTarget {
  PhoneDownloadTarget._(this._inner, this._handoff, this._file, this._saver);

  final FileDownloadTarget _inner;
  final Directory _handoff;
  final File _file;
  final PhoneFileSaver _saver;

  /// [cache] and [saver] are the app cache folder and the platform save step; tests pass their own.
  static Future<PhoneDownloadTarget> open(
    String filename, {
    required Directory cache,
    required PhoneFileSaver saver,
  }) async {
    final root = Directory('${cache.path}/$_handoffFolder');
    await root.create(recursive: true);
    await _sweepStale(root);
    final handoff = await root.createTemp('save_');
    final file = File(
      '${handoff.path}/${safeFileName(filename, windows: false)}',
    );
    final inner = await FileDownloadTarget.open(
      file,
      partDirectory: Directory('${cache.path}/downloads'),
    );
    return PhoneDownloadTarget._(inner, handoff, file, saver);
  }

  /// The platform's own cache folder, which the OS may clear when it needs room.
  static Future<Directory> appCache() => getApplicationCacheDirectory();

  @override
  int? get maxBytes => null;

  @override
  Future<void> write(List<int> chunk) => _inner.write(chunk);

  @override
  Future<bool> finish() async {
    try {
      await _inner.finish();
      return await _saver(_file, _file.uri.pathSegments.last);
    } finally {
      await _removeHandoff();
    }
  }

  @override
  Future<void> discard() async {
    await _inner.discard();
    await _removeHandoff();
  }

  Future<void> _removeHandoff() async {
    try {
      await _handoff.delete(recursive: true);
    } on FileSystemException catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Could not remove the finished download from the cache',
        error,
        stack,
      );
    }
  }

  static Future<void> _sweepStale(Directory root) async {
    final cutoff = DateTime.now().subtract(_staleAfter);
    try {
      await for (final entry in root.list()) {
        if ((await entry.stat()).modified.isBefore(cutoff)) {
          await entry.delete(recursive: true);
        }
      }
    } on FileSystemException catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Could not sweep old finished downloads',
        error,
        stack,
      );
    }
  }
}
