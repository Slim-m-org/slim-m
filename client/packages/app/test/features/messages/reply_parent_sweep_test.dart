// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A fetched reply parent is not in the local store, so the retention sweep
/// must not drop the extras its quote draws from.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/providers/reply_parent.dart';
import 'package:slimm_app/src/features/messages/providers/retention_sweep.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';

import '../../support/fake_api.dart';

const _key = (channelId: 'c1', messageId: 'm1');

http.Response _parent() => http.Response(
  jsonEncode({
    'id': 'm1',
    'channel_id': 'c1',
    'author_id': 'priya',
    'author_display_name': 'priya',
    'seq': 1,
    'content': 'the parent',
    'created_at': 1000,
    'reactions': [
      {'emoji': 'thumb', 'count': 1, 'reacted': false},
    ],
  }),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('a fetched reply parent keeps its extras through a sweep', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'me',
              accessToken: 'access',
              refreshToken: 'refresh',
              accessExpiresAt: 0,
            ),
          ),
        ),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        mockApiOverride((request) async => _parent()),
      ],
    );
    addTearDown(container.dispose);
    final held = container.listen(replyParentProvider(_key), (_, _) {});
    addTearDown(held.close);
    await container.read(replyParentProvider(_key).future);

    await runRetentionSweep(
      MessageStore(db),
      container.read(messageExtrasProvider.notifier),
      const {'c1'},
    );

    expect(container.read(messageExtrasProvider)['m1']?.reactions, isNotEmpty);
  });
}
