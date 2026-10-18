// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which version a rollback last went back from, kept past the one-shot
/// `rolled-back` marker the launcher writes.
///
/// The marker is consumed when the failure is reported, which is after the
/// startup update pass has already run. Without a record that outlives it, the
/// restored version sees the bad one as newer and installs it again on every
/// launch. The record keeps the highest version ever rolled back from, so
/// nothing at or below it is offered again.
library;

import 'dart:io';

import '../update_check.dart' show isNewer, parseVersion;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// The highest version rolled back from, read from the pending marker and the
/// durable [record] without consuming either. Null when there is none.
String? failedVersionFloor({required File rolledBack, required File record}) =>
    _highest(_read(rolledBack), _read(record));

/// The version the launcher rolled back from since the last call, if any.
/// Reading it clears the marker so the failure is reported once, and writes it
/// to [record] so it is never reinstalled.
String? takeRolledBack({required File rolledBack, required File record}) {
  if (!rolledBack.existsSync()) return null;
  final version = _read(rolledBack);
  if (version != null) {
    record.writeAsStringSync(_highest(version, _read(record))!);
  }
  try {
    rolledBack.deleteSync();
  } on FileSystemException catch (error, stack) {
    AppLog.swallowed(
      LogTag.platform,
      'A marker that cannot be removed is reported again next start; harmless',
      error,
      stack,
    );
  }
  return version;
}

/// [running] unless a rollback on record is at or above it.
String versionToUpdateFrom(String running, String? floor) =>
    floor != null && isNewer(floor, running) ? floor : running;

String? _read(File file) {
  try {
    final text = file.readAsStringSync().trim();
    return parseVersion(text) == null ? null : text;
  } on FileSystemException catch (error, stack) {
    AppLog.swallowed(LogTag.platform, 'read failed, ignored', error, stack);
    return null;
  }
}

String? _highest(String? a, String? b) {
  if (a == null) return b;
  if (b == null) return a;
  return isNewer(a, b) ? a : b;
}
