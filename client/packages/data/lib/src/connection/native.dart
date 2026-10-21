// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The native backend: SQLite3 Multiple Ciphers through `dart:ffi`, in one
/// encrypted file under the application support directory.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database_key.dart';
import 'encrypted_database.dart' show applyConnectionTuning, applyDatabaseKey;
import 'open_recovery.dart';

/// The file name is part of the contract with anyone debugging a user's
/// install, so it is fixed here rather than derived.
const slimmDatabaseFileName = 'slimm.sqlite';

/// Opens the on-disk database backing the local cache, encrypted with the key
/// in [keys].
///
/// [fileName] picks a different file for a further account; the default is
/// the one every install has used.
///
/// [onReset] is told when the cache had to be cleared because its key was
/// lost, so the app can say the data is being fetched again. Throws
/// [LocalDatabaseKeyUnavailable] when the key store cannot be reached.
///
/// Runs sqlite3 on a background isolate: every query on the platform that
/// ships to users therefore stays off the frame-building isolate.
Future<QueryExecutor> openSlimmDatabase({
  required DatabaseKeyStore keys,
  String? directoryPath,
  String? fileName,
  void Function(DatabaseResetReason reason)? onReset,
}) async {
  final directory =
      directoryPath ?? (await getApplicationSupportDirectory()).path;
  final file = File(p.join(directory, fileName ?? slimmDatabaseFileName));
  final prepared = await prepareOpenableDatabase(file: file, keys: keys);
  final reset = prepared.reset;
  if (reset != null) onReset?.call(reset);
  final key = prepared.key;
  return NativeDatabase.createInBackground(
    file,
    setup: (db) {
      applyDatabaseKey(db, key);
      applyConnectionTuning(db);
    },
  );
}
