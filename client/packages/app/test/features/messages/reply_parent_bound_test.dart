// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reply parents nothing is quoting are held only up to a bound, so a long
/// session does not keep a listener and a pin per parent it ever scrolled past.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/reply_parent.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../../support/fake_api.dart';

ReplyParentKey _key(int i) => (channelId: 'c1', messageId: 'm$i');

void main() {
  test('parents past the cache size are released', () async {
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
        mockApiOverride((request) async {
          final id = request.url.pathSegments.last;
          return http.Response(
            jsonEncode({
              'id': id,
              'channel_id': 'c1',
              'author_id': 'priya',
              'author_display_name': 'priya',
              'seq': 1,
              'content': 'parent $id',
              'created_at': 1000,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    const total = replyParentCacheCapacity + 5;
    for (var i = 0; i < total; i++) {
      final sub = container.listen(replyParentProvider(_key(i)), (_, _) {});
      await container.read(replyParentProvider(_key(i)).future);
      sub.close();
    }
    await Future<void>.delayed(Duration.zero);

    expect(container.exists(replyParentProvider(_key(0))), isFalse);
    expect(container.exists(replyParentProvider(_key(total - 1))), isTrue);
    final held = [
      for (var i = 0; i < total; i++)
        if (container.exists(replyParentProvider(_key(i)))) i,
    ];
    expect(held, hasLength(replyParentCacheCapacity));
  });
}
