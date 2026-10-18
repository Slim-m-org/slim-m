// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser backend: sqlite3 compiled to WebAssembly, hosted in a worker
/// so the query loop never blocks the frame.
///
/// Both asset names are fixed by what `web/` serves; see `web/README.md` in
/// the app package for where those two files come from and how to refresh
/// them. They are served from the app's own origin, never a CDN, so a
/// self-hosted deployment stays self-contained.
library;

import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

import 'database_key.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// The IndexedDB/OPFS database name. Changing it orphans every existing
/// browser's cache rather than migrating it.
const slimmDatabaseName = 'slimm';

/// The browser database for [fileName]: the legacy name for the default file,
/// the file's own name without its extension for any other.
String webDatabaseName(String? fileName) {
  if (fileName == null || fileName == 'slimm.sqlite') return slimmDatabaseName;
  return fileName.endsWith('.sqlite')
      ? fileName.substring(0, fileName.length - '.sqlite'.length)
      : fileName;
}

/// Opens the browser-backed database, letting drift pick the most durable
/// storage the browser offers: OPFS first, then IndexedDB, then memory.
///
/// The cache is disposable by design (see `SlimmDatabase`'s migration notes),
/// so an unlucky browser degrades to re-syncing rather than to losing
/// anything the server does not already hold.
///
/// Not encrypted, and [keys] goes unused: a browser has no place to keep a key
/// that script on the same origin cannot also read, so encrypting here would
/// be theatre. See docs/decisions/0042-encrypt-local-database.md.
Future<QueryExecutor> openSlimmDatabase({
  required DatabaseKeyStore keys,
  String? directoryPath,
  String? fileName,
  void Function(DatabaseResetReason reason)? onReset,
}) async {
  final result = await WasmDatabase.open(
    databaseName: webDatabaseName(fileName),
    sqlite3Uri: Uri.parse('sqlite3.wasm'),
    driftWorkerUri: Uri.parse('drift_worker.js'),
  );
  if (result.chosenImplementation == WasmStorageImplementation.inMemory) {
    // Said out loud because the symptom otherwise reads as a sync bug: every
    // reload starts from an empty channel list and refetches everything.
    AppLog.warning(
      LogTag.data,
      'no durable storage in this browser; the local cache is memory-only',
      context: {'missing': result.missingFeatures.join(', ')},
    );
  }
  return result.resolvedExecutor;
}
