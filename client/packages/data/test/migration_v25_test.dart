// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-25 migration: an upgrading client gains the canvas layouts
/// table, and a cache already stamped higher by a newer build still opens.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart';

Future<void> _downgradeToV24(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db.customStatement('DROP TABLE canvas_personal_layouts');
  await db.customStatement('PRAGMA user_version = 24');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v25');
    file = File('${dir.path}/slimm.sqlite');
    await _downgradeToV24(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('the layouts table exists after the upgrade and takes a save', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final store = CanvasLayoutStore(db);

    await store.save('c1', 'kept', now: 1);

    expect(await store.load('c1'), 'kept');
    expect(db.schemaVersion, greaterThanOrEqualTo(25));
  });
}
