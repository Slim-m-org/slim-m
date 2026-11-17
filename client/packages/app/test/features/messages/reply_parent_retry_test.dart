// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reply parent the server could not serve for a moment is fetched again
/// the next time a quote asks, instead of reading as gone all session.
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
  }),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('a failed fetch is tried again once nothing holds it', () async {
    var down = true;
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
        mockApiOverride(
          (request) async =>
              down ? http.Response('{"error":"down"}', 503) : _parent(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final first = container.listen(replyParentProvider(_key), (_, _) {});
    await expectLater(
      container.read(replyParentProvider(_key).future),
      throwsA(anything),
    );
    first.close();
    await Future<void>.delayed(Duration.zero);

    down = false;
    final again = container.listen(replyParentProvider(_key), (_, _) {});
    addTearDown(again.close);
    final parent = await container.read(replyParentProvider(_key).future);
    expect(parent?.content, 'the parent');
  });
}
