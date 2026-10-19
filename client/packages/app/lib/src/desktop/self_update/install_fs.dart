// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// File helpers every platform installer shares.
library;

import 'dart:io';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Deletes [entity] recursively; a locked or already-gone entry is left for the next cleanup pass.
void safeDelete(FileSystemEntity entity) {
  try {
    entity.deleteSync(recursive: true);
  } on FileSystemException catch (error, stack) {
    AppLog.swallowed(
      LogTag.platform,
      'Could not delete an old update file',
      error,
      stack,
    );
    return;
  }
}

/// One attempt at moving a directory; injectable so tests can fake a lock.
typedef RenameDirectory = Future<void> Function(Directory from, String to);

Future<void> renameDirectoryOnce(Directory from, String to) => from.rename(to);

/// Waits between attempts to move a directory a scanner may be holding open.
const renameBackoff = [
  Duration(milliseconds: 200),
  Duration(milliseconds: 500),
  Duration(seconds: 1),
  Duration(seconds: 2),
];

const _accessDenied = 5;
const _sharingViolation = 32;

bool _isTransientLock(FileSystemException error) {
  final code = error.osError?.errorCode;
  return code == _accessDenied || code == _sharingViolation;
}

/// Moves [from] to [to], retrying through [backoff] while Defender or the
/// search indexer holds a file inside it; any other failure is thrown at once.
Future<void> renameDirectoryWithRetry(
  Directory from,
  String to, {
  RenameDirectory rename = renameDirectoryOnce,
  List<Duration> backoff = renameBackoff,
}) async {
  for (var attempt = 0; ; attempt++) {
    try {
      await rename(from, to);
      return;
    } on FileSystemException catch (error) {
      if (attempt >= backoff.length || !_isTransientLock(error)) rethrow;
      await Future<void>.delayed(backoff[attempt]);
    }
  }
}
