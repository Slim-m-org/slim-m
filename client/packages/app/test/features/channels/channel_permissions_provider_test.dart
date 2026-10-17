// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Coverage for `channelPermissionsProvider`, `myChannelPermissionsProvider`,
/// and the invalidation cases `roleChangeWatcherProvider` gained for them -
/// see docs/decisions/0011-per-channel-permissions.md. Mirrors
/// `member_roster_paging_test.dart`'s shape for a live-event-driven
/// invalidation test.
///
/// **Every invalidation case here forces a read after the event, and that is
/// load-bearing rather than incidental.**
/// Riverpod invalidates lazily: nothing refetches until something asks for
/// the value again, so a test that only counts fetches after emitting an
/// event cannot observe whether the invalidation happened at all.
/// Two of these cases were written that way first and killed no mutation:
/// dropping the `userId == selfId` guard, and widening the surgical
/// per-channel invalidate to the whole family, both passed against fixtures
/// that never re-read.
/// The re-read is what turns each of them into a real assertion.
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

Map<String, dynamic> _meJson() => {
  'id': 'self',
  'username': 'self',
  'display_name': 'Self',
  'created_at': 0,
  'permissions': 0,
};

ProviderContainer _containerWith({
  required http.Client httpClient,
  Stream<api.ServerEvent>? liveEvents,
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
      if (liveEvents != null) liveEventsProvider.overrideWithValue(liveEvents),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('myChannelPermissionsProvider default value', () {
    test('reads as 0 while the fetch is still in flight', () async {
      final gate = Completer<void>();
      final container = _containerWith(
        httpClient: MockClient((request) async {
          await gate.future;
          return http.Response(jsonEncode({'permissions': 7}), 200);
        }),
      );

      final sub = container.listen(
        myChannelPermissionsProvider('chan-1'),
        (_, __) {},
      );
      expect(container.read(myChannelPermissionsProvider('chan-1')), 0);

      gate.complete();
      await container.read(channelPermissionsProvider('chan-1').future);
      expect(container.read(myChannelPermissionsProvider('chan-1')), 7);
      sub.close();
    });

    test(
      'reads as 0, not the caller\'s base bits, once the fetch fails',
      () async {
        final container = _containerWith(
          httpClient: MockClient(
            (request) async =>
                http.Response(jsonEncode({'error': 'boom'}), 500),
          ),
        );

        final sub = container.listen(
          myChannelPermissionsProvider('chan-1'),
          (_, __) {},
        );
        // Let the failed fetch settle before asserting the derived value.
        try {
          await container.read(channelPermissionsProvider('chan-1').future);
        } on api.ApiException {
          // Expected: the mock server answered 500.
        }
        expect(container.read(myChannelPermissionsProvider('chan-1')), 0);
        sub.close();
      },
    );
  });

  group('roleChangeWatcherProvider invalidation', () {
    test('a self MemberTimeoutChanged invalidates meProvider and the whole '
        'channel-permissions family; a MemberTimeoutChanged for someone else '
        'does neither', () async {
      var meFetchCount = 0;
      var permissionsFetchCount = 0;
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = _containerWith(
        httpClient: MockClient((request) async {
          if (request.url.path == '/me') {
            meFetchCount++;
            return http.Response(jsonEncode(_meJson()), 200);
          }
          permissionsFetchCount++;
          return http.Response(jsonEncode({'permissions': 1}), 200);
        }),
        liveEvents: events.stream,
      );

      final watcherSub = container.listen(
        roleChangeWatcherProvider,
        (_, __) {},
      );
      final meSub = container.listen(meProvider, (_, __) {});
      final permSub = container.listen(
        channelPermissionsProvider('chan-1'),
        (_, __) {},
      );
      await container.read(meProvider.future);
      await container.read(channelPermissionsProvider('chan-1').future);
      expect(meFetchCount, 1);
      expect(permissionsFetchCount, 1);

      events.add(
        const api.MemberTimeoutChanged(userId: 'someone-else', until: 1),
      );
      await Future<void>.delayed(Duration.zero);
      // Re-read, or an unread invalidation passes; see the library doc.
      await container.read(meProvider.future);
      await container.read(channelPermissionsProvider('chan-1').future);
      expect(
        meFetchCount,
        1,
        reason: 'a timeout on another member is not this caller going stale',
      );
      expect(permissionsFetchCount, 1);

      events.add(const api.MemberTimeoutChanged(userId: 'self', until: 1));
      await Future<void>.delayed(Duration.zero);
      await container.read(meProvider.future);
      await container.read(channelPermissionsProvider('chan-1').future);
      expect(meFetchCount, 2);
      expect(permissionsFetchCount, 2);

      watcherSub.close();
      meSub.close();
      permSub.close();
    });

    test('an OverwriteChanged invalidates only the channel it names, not an '
        'unrelated one', () async {
      var chan1FetchCount = 0;
      var chan2FetchCount = 0;
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = _containerWith(
        httpClient: MockClient((request) async {
          if (request.url.path == '/channels/chan-1/permissions') {
            chan1FetchCount++;
          } else if (request.url.path == '/channels/chan-2/permissions') {
            chan2FetchCount++;
          }
          return http.Response(jsonEncode({'permissions': 1}), 200);
        }),
        liveEvents: events.stream,
      );

      final watcherSub = container.listen(
        roleChangeWatcherProvider,
        (_, __) {},
      );
      final sub1 = container.listen(
        channelPermissionsProvider('chan-1'),
        (_, __) {},
      );
      final sub2 = container.listen(
        channelPermissionsProvider('chan-2'),
        (_, __) {},
      );
      await container.read(channelPermissionsProvider('chan-1').future);
      await container.read(channelPermissionsProvider('chan-2').future);
      expect(chan1FetchCount, 1);
      expect(chan2FetchCount, 1);

      events.add(const api.OverwriteChanged(channelId: 'chan-1'));
      await Future<void>.delayed(Duration.zero);
      // Re-read both, or an unread invalidation passes; see the library doc.
      await container.read(channelPermissionsProvider('chan-1').future);
      await container.read(channelPermissionsProvider('chan-2').future);

      expect(chan1FetchCount, 2);
      expect(
        chan2FetchCount,
        1,
        reason: 'an overwrite on chan-1 must not touch chan-2\'s cache',
      );

      watcherSub.close();
      sub1.close();
      sub2.close();
    });

    test('RoleChanged and MemberRoleChanged both invalidate the whole '
        'channel-permissions family', () async {
      var chan1FetchCount = 0;
      var chan2FetchCount = 0;
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = _containerWith(
        httpClient: MockClient((request) async {
          if (request.url.path == '/channels/chan-1/permissions') {
            chan1FetchCount++;
          } else if (request.url.path == '/channels/chan-2/permissions') {
            chan2FetchCount++;
          }
          return http.Response(jsonEncode({'permissions': 1}), 200);
        }),
        liveEvents: events.stream,
      );

      final watcherSub = container.listen(
        roleChangeWatcherProvider,
        (_, __) {},
      );
      final sub1 = container.listen(
        channelPermissionsProvider('chan-1'),
        (_, __) {},
      );
      final sub2 = container.listen(
        channelPermissionsProvider('chan-2'),
        (_, __) {},
      );
      await container.read(channelPermissionsProvider('chan-1').future);
      await container.read(channelPermissionsProvider('chan-2').future);
      expect(chan1FetchCount, 1);
      expect(chan2FetchCount, 1);

      events.add(const api.RoleChanged(roleId: 'role-1'));
      await Future<void>.delayed(Duration.zero);
      await container.read(channelPermissionsProvider('chan-1').future);
      await container.read(channelPermissionsProvider('chan-2').future);
      expect(chan1FetchCount, 2);
      expect(chan2FetchCount, 2);

      events.add(
        const api.MemberRoleChanged(userId: 'someone-else', roleId: 'r'),
      );
      await Future<void>.delayed(Duration.zero);
      await container.read(channelPermissionsProvider('chan-1').future);
      await container.read(channelPermissionsProvider('chan-2').future);
      expect(chan1FetchCount, 3);
      expect(chan2FetchCount, 3);

      watcherSub.close();
      sub1.close();
      sub2.close();
    });
  });
}
