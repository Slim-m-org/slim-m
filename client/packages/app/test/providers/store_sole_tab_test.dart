// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Only the sole live tab may call another run's pending sends abandoned.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';

Future<MessageStore> _openStore({required bool sole}) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWith((ref) => db),
      soleTabClaimProvider.overrideWithValue(() async => sole),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(db.close);
  await MessageStore(db).addPending(
    id: 'local-1',
    channelId: 'chan-1',
    authorId: 'user-1',
    content: 'in flight',
  );
  return container.read(storeProvider.future);
}

void main() {
  test('a second tab leaves the first tab pending sends pending', () async {
    final store = await _openStore(sole: false);

    final row = (await store.watchChannel('chan-1').first).single;
    expect(row.pending, isTrue);
    expect(row.failed, isFalse);
  });

  test('the sole tab still fails what a dead run left pending', () async {
    final store = await _openStore(sole: true);

    final row = (await store.watchChannel('chan-1').first).single;
    expect(row.pending, isFalse);
    expect(row.failed, isTrue);
  });
}
