// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Verifies every upgrade path between the committed drift schema snapshots
/// lands on the schema the Dart tables declare, so a step added without
/// updating `drift_schemas/` is caught here.
library;

import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart';

import 'generated/schema.dart';

void main() {
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('the snapshots cover the current schema version', () {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(
      () => GeneratedHelper()
          .databaseForVersion(NativeDatabase.memory(), db.schemaVersion),
      returnsNormally,
    );
  });

  test('a fresh install matches the current snapshot', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, db.schemaVersion);
  });

  test('v25 upgrades to the current schema', () async {
    final schema = await verifier.schemaAt(25);
    final db = SlimmDatabase(schema.newConnection());
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, db.schemaVersion);
  });
}
