// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// CQ1: `ChannelScreen` seeds a channel's extras (reactions, polls,
/// attachments, thread summaries) from `_hydrateExtras`, which ran only in
/// `initState`. A route that reuses this State across a channel switch - a
/// thread modal, whose `ChannelScreen` body changes its `channelId` in place -
/// therefore left the second channel's already-synced messages with no extras
/// until an unrelated live event happened to touch them. It now re-hydrates in
/// `didUpdateWidget` when the channel id changes, which this pins by driving a
/// real in-place channel switch and asserting the extras fetch fires for the
/// new channel.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/screens/channel_screen.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Message _message(String channelId, int seq) => api.Message(
  id: '$channelId-m$seq',
  channelId: channelId,
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: seq,
  content: 'message $seq',
  createdAt: seq * 1000,
  editedAt: null,
);

Map<String, dynamic> _meJson() => {
  'id': 'bob',
  'username': 'bob',
  'display_name': 'Bob',
  'created_at': 0,
  'permissions': 0,
};

http.Response _emptyList() => http.Response(
  jsonEncode(const <Object>[]),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets("switching channels re-hydrates the new channel's extras", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = SlimmDatabase(NativeDatabase.memory());
    final store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'first', kind: 'text', createdAt: 0),
      const api.Channel(id: 'c2', name: 'second', kind: 'text', createdAt: 1),
    ]);
    await store.applyMessages([_message('c1', 1), _message('c2', 1)]);

    // Channels whose extras were hydrated. _hydrateExtras fetches with no `before` cursor; channel_history's older-page fetch always carries one, so the missing cursor isolates hydration from paging.
    final hydrated = <String>[];
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => store),
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              final match = RegExp(
                r'^/channels/([^/]+)/messages$',
              ).firstMatch(request.url.path);
              if (request.method == 'GET' && match != null) {
                if (request.url.queryParameters['before'] == null) {
                  hydrated.add(match.group(1)!);
                }
                return _emptyList();
              }
              if (request.method == 'GET' && request.url.path == '/me') {
                return http.Response(
                  jsonEncode(_meJson()),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              if (request.method == 'PUT' &&
                  request.url.path.endsWith('/read')) {
                final body = jsonDecode(request.body) as Map<String, dynamic>;
                return http.Response(
                  jsonEncode({'last_read_seq': body['seq'], 'unread': 0}),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              return _emptyList();
            }),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );

    // Drive the id through a ValueNotifier so only ChannelScreen rebuilds in place: the State is reused and didUpdateWidget fires (the thread-modal path), where pumping a whole fresh tree would build a new State and run initState, testing nothing.
    final channelId = ValueNotifier<String>('c1');
    addTearDown(channelId.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ValueListenableBuilder<String>(
              valueListenable: channelId,
              builder: (context, id, _) => ChannelScreen(channelId: id),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(hydrated, contains('c1'), reason: 'the first channel hydrates');

    hydrated.clear();
    channelId.value = 'c2';
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      hydrated,
      contains('c2'),
      reason:
          'a channel switch must re-hydrate the new channel, not just the '
          'first channel mounted',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    await db.close();
  });
}
