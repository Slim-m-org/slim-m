// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A second connection holding the write lock makes a local write wait
/// instead of failing with SQLITE_BUSY ("database is locked", code 5).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:slimm_data/data.dart';
import 'package:slimm_data/src/connection/encrypted_database.dart';
import 'package:slimm_data/src/connection/native.dart'
    show slimmDatabaseFileName;
import 'package:sqlite3/sqlite3.dart';

class _Keys implements DatabaseKeyStore {
  String? key;

  @override
  Future<String?> read() async => key;

  @override
  Future<void> write(String value) async => key = value;
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('db-lock-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a write waits for another connection instead of failing', () async {
    final keys = _Keys();
    final db = SlimmDatabase(
      await openSlimmDatabase(keys: keys, directoryPath: dir.path),
    );
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.setReadMarker('c1', 1);

    final other = sqlite3.open(p.join(dir.path, slimmDatabaseFileName));
    applyDatabaseKey(other, keys.key!);
    other.execute('BEGIN IMMEDIATE');
    final release = Future<void>.delayed(
      const Duration(milliseconds: 400),
      () {
        other.execute('COMMIT');
        other.close();
      },
    );

    await store.setReadMarker('c1', 2);
    await release;
  });
}
