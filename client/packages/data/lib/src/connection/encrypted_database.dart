// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Getting the on-disk database into a state where it opens with the key:
/// created encrypted, migrated from plaintext, or reset when the key is gone.
///
/// Every path either leaves the live file exactly as it was or replaces it
/// atomically, and none of them opens a plaintext file for the app to use.
/// See docs/decisions/0042-encrypt-local-database.md for the reasoning.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/sqlite3.dart';

import 'database_key.dart';

const _plainHeader = 'SQLite format 3\u0000';
const _sqliteNotADatabase = 26;
const _sqliteCorrupt = 11;
final _keyPattern = RegExp(r'^[0-9a-f]{64}$');

/// The file the plaintext copy is encrypted into before it replaces the live
/// one. A leftover from a crashed run is disposable and deleted on the next.
String _stagingPath(File live) => '${live.path}.encrypting';

/// Applies [key] to a freshly opened connection, refusing to go on when the
/// linked SQLite has no cipher. Raw-key form skips the password KDF, which is
/// pointless for a 256-bit random key and would cost every open. The SQLCipher
/// profile keeps the file readable by stock tools.
void applyDatabaseKey(Database db, String key) {
  if (!_keyPattern.hasMatch(key)) {
    throw ArgumentError('the database key is not 64 lowercase hex digits');
  }
  _sanitized(() {
    _selectCipher(db);
    db.execute('''PRAGMA key = "x'$key'"''');
  });
  _requireCipher(db);
  db.execute('PRAGMA temp_store = MEMORY');
}

void _selectCipher(Database db) {
  db.execute("PRAGMA cipher = 'sqlcipher'");
  db.execute('PRAGMA legacy = 4');
}

/// Stock SQLite treats `PRAGMA key` and `PRAGMA rekey` as no-ops, so the only
/// way to know encryption is real is to ask the library for a function only
/// the cipher build has.
void _requireCipher(Database db) {
  try {
    db.select('SELECT sqlite3mc_version()');
  } on SqliteException catch (error) {
    if (!error.message.contains('no such function')) {
      throw DatabaseCipherException(error.resultCode, error.message);
    }
    throw const DatabaseEncryptionUnavailable(
      'the linked SQLite is not the multiple-ciphers build',
    );
  }
}

/// Runs statements that carry the key and rethrows a failure without the
/// statement text, which is where the key would otherwise reach a log.
@visibleForTesting
T sanitizeCipherErrors<T>(T Function() body) => _sanitized(body);

T _sanitized<T>(T Function() body) {
  try {
    return body();
  } on SqliteException catch (error) {
    throw DatabaseCipherException(error.resultCode, error.message);
  }
}

/// A database file that opens with [key], and why the cache was cleared on the
/// way there ([reset] is null when nothing was).
typedef PreparedDatabase = ({String key, DatabaseResetReason? reset});

/// Makes [file] safe to open with the stored key.
///
/// Throws [LocalDatabaseKeyUnavailable] when the key store cannot be reached,
/// and [DatabaseEncryptionUnavailable] when the linked SQLite cannot encrypt;
/// the file is not touched in either case. An advisory lock keeps two app
/// instances from each minting a key for the same file.
Future<PreparedDatabase> prepareEncryptedDatabase({
  required File file,
  required DatabaseKeyStore keys,
}) {
  final run = _inProcess.then((_) => _prepareLocked(file, keys));
  _inProcess = run.then((_) {}, onError: (_) {});
  return run;
}

/// The file lock is per process on POSIX, so callers in this process queue
/// here and the lock only has to arbitrate between processes.
Future<void> _inProcess = Future<void>.value();

Future<PreparedDatabase> _prepareLocked(
  File file,
  DatabaseKeyStore keys,
) async {
  await file.parent.create(recursive: true);
  final lock = await File('${file.path}.lock').open(mode: FileMode.write);
  try {
    await lock.lock(FileLock.blockingExclusive);
    return await _prepare(file, keys);
  } finally {
    await lock.close();
  }
}

Future<PreparedDatabase> _prepare(File file, DatabaseKeyStore keys) async {
  final memory = sqlite3.openInMemory();
  try {
    _requireCipher(memory);
  } finally {
    memory.close();
  }
  _removeStaging(file);
  final stored = _wellFormed(await _readKey(keys));
  switch (_stateOf(file)) {
    case _FileState.missing:
      _removeSidecars(file);
      return (key: stored ?? await _mintKey(keys), reset: null);
    case _FileState.plaintext:
      final key = stored ?? await _mintKey(keys);
      return (key: key, reset: _migratePlaintext(file, key));
    case _FileState.opaque:
      if (stored == null) {
        _deleteDatabase(file);
        const reset = DatabaseResetReason.keyMissing;
        return (key: await _mintKey(keys), reset: reset);
      }
      switch (_probe(file, stored)) {
        case _Probe.opens:
          return (key: stored, reset: null);
        case _Probe.wrongKey:
          _deleteDatabase(file);
        case _Probe.damaged:
          _quarantine(file);
        case _Probe.unavailable:
          return (key: stored, reset: null);
      }
      return (key: stored, reset: DatabaseResetReason.unreadable);
  }
}

/// A stored value that is not a well-formed key is as good as no key.
String? _wellFormed(String? key) =>
    key != null && _keyPattern.hasMatch(key) ? key : null;

Future<String?> _readKey(DatabaseKeyStore keys) async {
  try {
    return await keys.read();
  } catch (error) {
    throw LocalDatabaseKeyUnavailable(error);
  }
}

/// Stores a new key and reads it back before anything is encrypted with it: a
/// database sealed with a key the store did not really keep is a database the
/// next launch has to throw away.
Future<String> _mintKey(DatabaseKeyStore keys) async {
  final key = generateDatabaseKey();
  try {
    await keys.write(key);
    if (await keys.read() != key) {
      throw StateError('the key store did not return the key it was given');
    }
  } catch (error) {
    throw LocalDatabaseKeyUnavailable(error);
  }
  return key;
}

enum _FileState { missing, plaintext, opaque }

_FileState _stateOf(File file) {
  if (!file.existsSync() || file.lengthSync() == 0) return _FileState.missing;
  final raf = file.openSync();
  try {
    final head = String.fromCharCodes(raf.readSync(_plainHeader.length));
    return head == _plainHeader ? _FileState.plaintext : _FileState.opaque;
  } finally {
    raf.closeSync();
  }
}

/// Encrypts a copy of the plaintext file, proves the copy reads back, then
/// renames it over the original.
///
/// Until that rename the plaintext file is untouched, so a crash at any earlier
/// point leaves the user's data exactly where it was and the next launch starts
/// again. The rename is the only step that changes what is on disk.
DatabaseResetReason? _migratePlaintext(File file, String key) {
  final staging = File(_stagingPath(file));
  try {
    _copyEncrypted(file, staging, key);
  } on SqliteException catch (error) {
    _removeStaging(file);
    if (!_isUnreadable(error.resultCode)) rethrow;
    _deleteDatabase(file);
    return DatabaseResetReason.unreadable;
  } catch (_) {
    _removeStaging(file);
    rethrow;
  }
  _removeSidecars(file);
  staging.renameSync(file.path);
  return null;
}

void _copyEncrypted(File source, File staging, String key) {
  final expected = _snapshotInto(source, staging);
  final copy = sqlite3.open(staging.path);
  try {
    _requireCipher(copy);
    _sanitized(() {
      _selectCipher(copy);
      // Encrypts the copy in place; it is disposable, so nothing is at risk.
      copy.execute('''PRAGMA rekey = "x'$key'"''');
    });
  } finally {
    copy.close();
  }
  if (_startsWithPlainHeader(staging)) {
    throw const DatabaseEncryptionUnavailable(
      'the copy is still plaintext after the rekey',
    );
  }
  final check = sqlite3.open(staging.path);
  try {
    applyDatabaseKey(check, key);
    final integrity = _sanitized(
      () => check.select('PRAGMA integrity_check').first.values.first,
    );
    if (integrity != 'ok') {
      throw StateError('the encrypted copy failed its integrity check');
    }
    if (!_sameCounts(expected, _sanitized(() => _tableCounts(check)))) {
      throw StateError('the encrypted copy does not match the original');
    }
  } finally {
    check.close();
  }
}

/// A consistent single-file snapshot of [source], WAL content included, and
/// the row count of every table in it. The staging file is made private
/// before the plaintext snapshot is written into it.
Map<String, int> _snapshotInto(File source, File target) {
  target.createSync();
  _restrictToOwner(target);
  final db = sqlite3.open(source.path);
  try {
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    db.execute("VACUUM INTO '${target.path.replaceAll("'", "''")}'");
    return _tableCounts(db);
  } finally {
    db.close();
  }
}

Map<String, int> _tableCounts(Database db) {
  final names = db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name NOT LIKE 'sqlite_%'",
  );
  return {
    for (final row in names)
      row['name'] as String: db
          .select(
              'SELECT count(*) AS n FROM "${_quoted(row['name'] as String)}"')
          .first['n'] as int,
  };
}

String _quoted(String name) => name.replaceAll('"', '""');

bool _sameCounts(Map<String, int> a, Map<String, int> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

/// What the staging step needs from the host, gathered so a test can stand in
/// for a phone: `Platform.operatingSystem` is the real one and cannot be faked.
@visibleForTesting
class StagingHost {
  const StagingHost({required this.operatingSystem, required this.run});

  final String operatingSystem;
  final ProcessResult Function(String executable, List<String> arguments) run;
}

@visibleForTesting
StagingHost stagingHost = StagingHost(
  operatingSystem: Platform.operatingSystem,
  run: Process.runSync,
);

/// Whether a new file has to have its mode narrowed by hand there.
///
/// Only where other accounts share the disk. A phone keeps each app's files
/// in a container no other app can read, and iOS cannot start a process at
/// all: the `chmod` this used to run there failed on every launch, so an
/// install with data from before encryption could never open it again.
bool _narrowsMode(String operatingSystem) =>
    operatingSystem == 'linux' || operatingSystem == 'macos';

void _restrictToOwner(File file) {
  if (!_narrowsMode(stagingHost.operatingSystem)) return;
  final result = stagingHost.run('chmod', ['600', file.path]);
  if (result.exitCode != 0) {
    throw FileSystemException('chmod 600 failed: ${result.stderr}', file.path);
  }
}

bool _startsWithPlainHeader(File file) =>
    _stateOf(file) == _FileState.plaintext;

enum _Probe { opens, wrongKey, damaged, unavailable }

/// Tells a wrong key (the file does not decrypt at all) from a file that
/// decrypts but is damaged, because the second is worth keeping.
///
/// A file that is busy or refuses to open says nothing about its contents, so
/// it is left alone for the caller's own retry to judge.
_Probe _probe(File file, String key) {
  Database? opened;
  try {
    final db = opened = sqlite3.open(file.path);
    applyDatabaseKey(db, key);
    _sanitized(() => db.select('SELECT count(*) FROM sqlite_master'));
    return _Probe.opens;
  } on DatabaseCipherException catch (error) {
    if (error.resultCode == _sqliteNotADatabase) return _Probe.wrongKey;
    if (error.resultCode == _sqliteCorrupt) return _Probe.damaged;
    if (_isUnavailable(error.resultCode)) return _Probe.unavailable;
    rethrow;
  } on SqliteException catch (error) {
    if (_isUnavailable(error.resultCode)) return _Probe.unavailable;
    rethrow;
  } finally {
    opened?.close();
  }
}

bool _isUnavailable(int resultCode) =>
    const {5, 6, 10, 14}.contains(resultCode);

bool _isUnreadable(int resultCode) =>
    resultCode == _sqliteNotADatabase || resultCode == _sqliteCorrupt;

/// Moves an unreadable-but-encrypted file aside instead of deleting it, so a
/// corruption that turns out to be fixable is not made permanent. One copy is
/// kept; it is still encrypted, so it leaks nothing.
void _quarantine(File file) {
  _removeSidecars(file);
  final aside = File('${file.path}.corrupt');
  if (aside.existsSync()) aside.deleteSync();
  file.renameSync(aside.path);
}

void _deleteDatabase(File file) {
  _removeSidecars(file);
  if (file.existsSync()) file.deleteSync();
}

void _removeSidecars(File file) {
  for (final suffix in const ['-wal', '-shm', '-journal']) {
    final sidecar = File('${file.path}$suffix');
    if (sidecar.existsSync()) sidecar.deleteSync();
  }
}

void _removeStaging(File live) {
  final staging = File(_stagingPath(live));
  _removeSidecars(staging);
  if (staging.existsSync()) staging.deleteSync();
}
