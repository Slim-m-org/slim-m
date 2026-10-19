// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An older build that opens this cache (a zip copy beside the setup install)
/// stamps its own lower schema version but keeps the newer columns. The next
/// open by a current build must upgrade past them instead of failing every
/// query with "duplicate column name".
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/src/database.dart';

Future<void> _currentCacheStampedAs(File file, int version) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await db.into(db.channels).insert(
        ChannelsCompanion.insert(
          id: 'chan-1',
          name: 'general',
          kind: 'text',
          createdAt: 900,
        ),
      );
  await db.customStatement('PRAGMA user_version = $version');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-downgraded-stamp');
    file = File('${dir.path}/slimm.sqlite');
  });

  tearDown(() => dir.delete(recursive: true));

  for (final stamped in [23, 21, 11]) {
    test('a current cache stamped back to v$stamped opens and keeps its rows',
        () async {
      await _currentCacheStampedAs(file, stamped);
      final db = SlimmDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final row = await db.select(db.channels).getSingle();
      expect(row.name, 'general');
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), db.schemaVersion);
    });
  }
}
