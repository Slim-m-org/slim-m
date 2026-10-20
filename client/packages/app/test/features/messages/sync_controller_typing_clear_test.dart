// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Regression test for a typing indicator that stuck for half an hour on the
/// live deployment: somebody closed the app and everyone else kept seeing
/// "is typing" until they left the channel.
///
/// `typing.stopped` is ephemeral and has no REST resync, so a session that
/// misses the frame - because the hub closed its connection for lagging, or
/// because the server restarted and lost both the tracker and its pending
/// expiry timers - never learns typing ended. Every one of those paths drops
/// the socket, so `SyncController.start()` clearing the state on a fresh
/// connect is what recovers it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/messages/providers/typing_controller.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _channelId = 'c1';

void main() {
  test('a (re)connect forgets who was typing', () async {
    final events = StreamController<ServerEvent>.broadcast();
    addTearDown(events.close);

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            // The reconnect only needs to reach the clear, not to complete.
            httpClient: MockClient((request) async {
              return http.Response('unavailable', 500);
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);

    // Wait out the constructor's own initial start() before the reconnect below.
    await container.read(syncControllerProvider.notifier).start();

    final sub = container.listen(
      typingControllerProvider(_channelId),
      (_, __) {},
    );
    addTearDown(sub.close);

    events.add(const TypingStarted(channelId: _channelId, userId: 'kiki'));
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(typingControllerProvider(_channelId)),
      contains('kiki'),
      reason: 'the start frame must light the indicator in the first place',
    );

    // The stop frame never arrives: this is the socket dropping instead.
    await container.read(syncControllerProvider.notifier).start();

    expect(
      container.read(typingControllerProvider(_channelId)),
      isEmpty,
      reason:
          'a fresh connect must not carry typing state whose stop frame it '
          'may have missed while it was away',
    );
  });
}
