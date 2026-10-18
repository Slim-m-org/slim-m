// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Proves the prepared database actually opens before the background isolate
/// is given it, because a failure inside that isolate reaches the UI only as a
/// `DriftRemoteException` that names nothing.
///
/// The file is a cache that re-syncs from the server, so one that cannot be
/// opened is set aside and replaced. The one exception is a file another live
/// process holds: replacing that would pull the file out from under it.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:sqlite3/sqlite3.dart';

import 'database_key.dart';
import 'encrypted_database.dart';

const _sqliteBusy = 5;
const _sqliteLocked = 6;
const _sqliteIoError = 10;
const _sqliteCantOpen = 14;

/// Windows reports a file another process has open without sharing as these.
const _windowsSharingViolations = {32, 33};

const _defaultBackoff = [
  Duration(milliseconds: 200),
  Duration(milliseconds: 500),
  Duration(seconds: 1),
  Duration(seconds: 2),
];

/// Why a probe could not open the database.
class OpenFailure {
  const OpenFailure(this.resultCode, this.message);

  final int resultCode;
  final String message;

  /// A lock or a sharing refusal passes when the other holder lets go.
  bool get transient =>
      resultCode == _sqliteBusy ||
      resultCode == _sqliteLocked ||
      resultCode == _sqliteIoError ||
      resultCode == _sqliteCantOpen;

  /// Held through SQLite's own locking, which only a live process can do.
  bool get heldByLock =>
      resultCode == _sqliteBusy || resultCode == _sqliteLocked;

  @override
  String toString() => 'sqlite result $resultCode: $message';
}

/// What recovery needs from the machine, so a test can stand in for a second
/// process holding an exclusive handle, which a Linux test cannot create.
@visibleForTesting
class OpenRecoveryHost {
  const OpenRecoveryHost({
    this.backoff = _defaultBackoff,
    this.probe = probeOpen,
    this.setAside = setDatabaseAside,
  });

  final List<Duration> backoff;
  final OpenFailure? Function(File file, String key) probe;
  final void Function(File file) setAside;
}

/// Opens [file] with [key] the way the background isolate will, and reports
/// why it could not; null means it opens.
OpenFailure? probeOpen(File file, String key) {
  Database? db;
  try {
    db = sqlite3.open(file.path);
    applyDatabaseKey(db, key);
    db.select('SELECT count(*) FROM sqlite_master');
    return null;
  } on SqliteException catch (error) {
    return OpenFailure(error.resultCode, error.message);
  } on DatabaseCipherException catch (error) {
    return OpenFailure(error.resultCode, error.message);
  } finally {
    db?.close();
  }
}

/// Moves an unopenable file, and what SQLite keeps beside it, out of the way.
void setDatabaseAside(File file) {
  final aside = File('${file.path}.unopenable');
  if (aside.existsSync()) aside.deleteSync();
  file.renameSync(aside.path);
  for (final suffix in const ['-wal', '-shm', '-journal']) {
    final sidecar = File('${file.path}$suffix');
    if (sidecar.existsSync()) sidecar.deleteSync();
  }
}

/// Like [prepareEncryptedDatabase], but the file it returns has been opened.
///
/// Throws [DatabaseInUseElsewhere] when a live process holds it and
/// [DatabaseUnopenable] when a fresh file cannot be had either.
Future<PreparedDatabase> prepareOpenableDatabase({
  required File file,
  required DatabaseKeyStore keys,
  OpenRecoveryHost host = const OpenRecoveryHost(),
}) async {
  late PreparedDatabase prepared;
  final failure = await _retrying(file, host, () async {
    prepared = await prepareEncryptedDatabase(file: file, keys: keys);
    return host.probe(file, prepared.key);
  });
  if (failure == null) return prepared;
  if (failure.heldByLock) throw DatabaseInUseElsewhere(failure.toString());
  _setAside(file, failure, host);
  final fresh = await prepareEncryptedDatabase(file: file, keys: keys);
  final again = host.probe(file, fresh.key);
  if (again != null) throw DatabaseUnopenable(again.toString());
  return (key: fresh.key, reset: DatabaseResetReason.unreadable);
}

/// Runs [attempt] until it reports no failure or a failure retrying cannot fix.
Future<OpenFailure?> _retrying(
  File file,
  OpenRecoveryHost host,
  Future<OpenFailure?> Function() attempt,
) async {
  OpenFailure? failure;
  for (var tries = 0; tries <= host.backoff.length; tries++) {
    failure = await _guarded(attempt);
    if (failure == null) return null;
    AppLog.warning(
      LogTag.data,
      'The local database did not open',
      error: failure,
      context: {'attempt': tries + 1, 'file': file.uri.pathSegments.last},
    );
    if (!failure.transient || tries == host.backoff.length) break;
    await Future<void>.delayed(host.backoff[tries]);
  }
  return failure;
}

/// A file Windows will not share fails before SQLite is ever asked; that is
/// the same condition as SQLite's own refusal to open.
Future<OpenFailure?> _guarded(Future<OpenFailure?> Function() attempt) async {
  try {
    return await attempt();
  } on FileSystemException catch (error) {
    if (!_windowsSharingViolations.contains(error.osError?.errorCode)) rethrow;
    return OpenFailure(_sqliteCantOpen, error.message);
  }
}

void _setAside(File file, OpenFailure failure, OpenRecoveryHost host) {
  try {
    host.setAside(file);
  } on FileSystemException catch (error) {
    final code = error.osError?.errorCode;
    if (_windowsSharingViolations.contains(code)) {
      throw DatabaseInUseElsewhere('$failure; ${error.message}');
    }
    throw DatabaseUnopenable('$failure; ${error.message}');
  }
  AppLog.warning(
    LogTag.data,
    'The unopenable local database was set aside; a fresh cache starts',
    error: failure,
  );
}
