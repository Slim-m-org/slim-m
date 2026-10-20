// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Mark as unread is gated on the newest message's age, read off the
/// transcript: a rail row's cursor lags while a channel stays unread.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_latest_message_at.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';

void main() {
  final now = DateTime(2026, 10, 19, 12);

  test('offersMarkUnread holds at the one hour boundary', () {
    int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;
    expect(offersMarkUnread(null, now), isFalse);
    expect(offersMarkUnread(ago(const Duration(minutes: 59)), now), isTrue);
    expect(offersMarkUnread(ago(const Duration(hours: 1)), now), isFalse);
  });

  test('the real provider follows the newest message, not a cursor', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    final store = MessageStore(db);
    final container = ProviderContainer(
      overrides: [storeProvider.overrideWith((ref) async => store)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final sub = container.listen(
      channelLatestMessageAtProvider('c1'),
      (_, _) {},
    );
    for (var seq = 1; seq <= 3; seq++) {
      await store.applyMessage(
        api.Message(
          id: 'm$seq',
          channelId: 'c1',
          authorId: 'u',
          authorDisplayName: 'U',
          seq: seq,
          content: 'hi',
          createdAt: seq * 1000,
          editedAt: null,
        ),
      );
    }
    await pumpEventQueue();
    expect(sub.read().valueOrNull, 3000);
  });
}
