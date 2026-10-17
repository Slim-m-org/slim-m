// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `myVisibleChannelsProvider`'s live invalidation, added when the
/// 2026-08-11 review found no event branch invalidated it at all: a channel
/// hidden or revealed by a role, timeout or overwrite change stayed stale in
/// the Space settings section until re-entry. Mirrors
/// `channel_permissions_provider_test.dart`'s harness, including its rule
/// that every case forces a read after the event - Riverpod invalidates
/// lazily, so a fetch count alone observes nothing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _containerWith({
  required http.Client httpClient,
  required Stream<api.ServerEvent> liveEvents,
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: httpClient,
        );
        ref.onDispose(client.close);
        return client;
      }),
      liveEventsProvider.overrideWithValue(liveEvents),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

typedef _Fixture = ({
  ProviderContainer container,
  StreamController<api.ServerEvent> events,
  int Function() fetchCount,
});

_Fixture _fixture() {
  var fetches = 0;
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final container = _containerWith(
    httpClient: MockClient((request) async {
      if (request.url.path == '/channels') fetches++;
      return http.Response(jsonEncode(<Object>[]), 200);
    }),
    liveEvents: events.stream,
  );
  return (container: container, events: events, fetchCount: () => fetches);
}

Future<int> _fetchesAfter(_Fixture f, api.ServerEvent event) async {
  f.events.add(event);
  await Future<void>.delayed(Duration.zero);
  // Re-read, or an unread invalidation passes; see the library doc.
  await f.container.read(myVisibleChannelsProvider.future);
  return f.fetchCount();
}

void main() {
  for (final (name, event) in [
    ('RoleChanged', const api.RoleChanged(roleId: 'r1') as api.ServerEvent),
    (
      'MemberRoleChanged',
      const api.MemberRoleChanged(userId: 'u1', roleId: 'r1'),
    ),
    (
      'a self MemberTimeoutChanged',
      const api.MemberTimeoutChanged(userId: 'self', until: 1),
    ),
    ('OverwriteChanged', const api.OverwriteChanged(channelId: 'c1')),
  ]) {
    test('$name invalidates myVisibleChannelsProvider', () async {
      final f = _fixture();
      final watcher = f.container.listen(roleChangeWatcherProvider, (_, __) {});
      final sub = f.container.listen(myVisibleChannelsProvider, (_, __) {});
      await f.container.read(myVisibleChannelsProvider.future);
      expect(f.fetchCount(), 1);

      expect(await _fetchesAfter(f, event), 2);
      watcher.close();
      sub.close();
    });
  }

  test(
    'a MemberTimeoutChanged for someone else leaves the list alone',
    () async {
      final f = _fixture();
      final watcher = f.container.listen(roleChangeWatcherProvider, (_, __) {});
      final sub = f.container.listen(myVisibleChannelsProvider, (_, __) {});
      await f.container.read(myVisibleChannelsProvider.future);
      expect(f.fetchCount(), 1);

      expect(
        await _fetchesAfter(
          f,
          const api.MemberTimeoutChanged(userId: 'someone-else', until: 1),
        ),
        1,
        reason: 'a timeout on another member is not this caller going stale',
      );
      watcher.close();
      sub.close();
    },
  );
}
