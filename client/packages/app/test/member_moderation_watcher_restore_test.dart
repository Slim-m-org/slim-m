// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `memberModerationWatcherProvider` refetches the roster on
/// [api.MemberRestored], the case the 2026-08-11 review added: a removed
/// member let back in stayed off every open member pane until an unrelated
/// refetch. Forces a read after the event, per
/// `channel_permissions_provider_test.dart`'s rule - Riverpod invalidates
/// lazily, so a fetch count alone observes nothing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  test('a MemberRestored event refetches the roster', () async {
    var fetches = 0;
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.url.path == '/members') fetches++;
              return http.Response(jsonEncode(<Object>[]), 200);
            }),
          );
          ref.onDispose(client.close);
          return client;
        }),
        liveEventsProvider.overrideWithValue(events.stream),
      ],
    );
    addTearDown(container.dispose);

    final watcher = container.listen(
      memberModerationWatcherProvider,
      (_, __) {},
    );
    final sub = container.listen(membersProvider, (_, __) {});
    await container.read(membersProvider.future);
    expect(fetches, 1);

    events.add(const api.MemberRestored(userId: 'bob'));
    await Future<void>.delayed(memberRosterRefetchDelay * 2);
    // Re-read, or an unread invalidation passes; see the library doc.
    await container.read(membersProvider.future);
    expect(fetches, 2, reason: 'a restore must put the member back on screen');

    watcher.close();
    sub.close();
  });
}
