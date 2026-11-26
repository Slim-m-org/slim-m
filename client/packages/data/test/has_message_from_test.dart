// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The first-run gate asks whether an account has ever written here.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart';

void main() {
  late SlimmDatabase db;
  late MessageStore store;

  setUp(() {
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  test('is false for an author with no rows, true once one exists', () async {
    await store.addPending(
      id: 'm1',
      channelId: 'chan-1',
      authorId: 'user-1',
      content: 'hello',
    );
    expect(await hasMessageFrom(store, 'user-2'), isFalse);
    expect(await hasMessageFrom(store, 'user-1'), isTrue);
  });

  test('hasMessageFromIn looks at one channel only', () async {
    await store.addPending(
      id: 'm1',
      channelId: 'chan-1',
      authorId: 'user-1',
      content: 'hello',
    );
    expect(await hasMessageFromIn(store, 'chan-1', 'user-1'), isTrue);
    expect(await hasMessageFromIn(store, 'chan-2', 'user-1'), isFalse);
    expect(await hasMessageFromIn(store, 'chan-1', 'user-2'), isFalse);
  });
}
