// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sign out warns with this count before wiping the store.
library;

import 'package:drift/native.dart';
import 'package:slimm_data/data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unsentCount counts pending and failed sends, not delivered ones',
      () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    for (final id in ['p1', 'p2', 'f1']) {
      await store.addPending(
        id: id,
        channelId: 'c1',
        authorId: 'me',
        content: id,
      );
    }
    await store.markFailed('f1', reason: 'offline');
    expect(await store.unsentCount(), 3);
    await store.discard('p1');
    expect(await store.unsentCount(), 2);
  });
}
