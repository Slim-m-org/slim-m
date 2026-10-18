// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The backend for a platform with neither `dart:ffi` nor `dart:js_interop`.
///
/// Nothing slim-m targets lands here today. It exists because a conditional
/// export needs a default branch, and a default that throws with a readable
/// message beats one that silently resolves to the wrong sqlite3.
library;

import 'package:drift/drift.dart';

import 'database_key.dart';

/// Always throws: there is no sqlite3 this build can reach.
Future<QueryExecutor> openSlimmDatabase({
  required DatabaseKeyStore keys,
  String? directoryPath,
  String? fileName,
  void Function(DatabaseResetReason reason)? onReset,
}) {
  throw UnsupportedError(
    'no sqlite3 backend compiled for this platform',
  );
}
