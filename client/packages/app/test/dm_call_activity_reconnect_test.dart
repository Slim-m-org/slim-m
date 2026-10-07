// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The DM row's call indicator: the in-app half of `docs/IMPLIED-GAPS.md` #2
/// - a call already happening in a DM shows on its rail row, and tapping the
/// row while it is lit opens straight into the call pane rather than the
/// plain transcript.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/dm_call_activity.dart';
import 'package:slimm_app/src/providers/dms.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/dm_row.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Channel _dm(String id, String name, String peerId) => Channel(
  id: id,
  name: name,
  kind: dmChannelKind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  dmParticipantId: peerId,
);

var rosterNow = <Map<String, String>>[];
var rosterCalls = 0;

ProviderContainer _container({required List<Map<String, String>> roster}) {
  final db = SlimmDatabase(NativeDatabase.memory());
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      databaseProvider.overrideWith((ref) async {
        ref.onDispose(db.close);
        return db;
      }),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/voice/roster')) {
              rosterCalls++;
              return http.Response(
                jsonEncode({'participants': rosterNow}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('', 204);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
}

Widget _harness(ProviderContainer container, GoRouter router) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    );

GoRouter _router(Channel channel) => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) =>
          Scaffold(body: DmRow(channel: channel, selected: false)),
    ),
    GoRoute(
      path: '/channels/:channelId',
      builder: (context, state) =>
          Scaffold(body: Text('channel:${state.pathParameters['channelId']}')),
    ),
  ],
);

void main() {
  testWidgets(
    'a call that started while disconnected shows after a reconnect',
    (tester) async {
      rosterNow = [];
      rosterCalls = 0;
      final channel = _dm('dm-1', 'Priya', 'user-priya');
      final container = _container(roster: const []);
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(container, _router(channel)));
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(AppIcons.startCall), findsNothing);
      final before = rosterCalls;

      // What SyncController.start does on every (re)connect.
      container.read(dmCallActivityProvider.notifier).clear();
      // The call began while the socket was down.
      rosterNow = [
        {'user_id': 'user-priya', 'display_name': 'Priya'},
      ];
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(rosterCalls, greaterThan(before), reason: 'row never re-asked');
      expect(find.byIcon(AppIcons.startCall), findsOneWidget);
    },
  );
}
