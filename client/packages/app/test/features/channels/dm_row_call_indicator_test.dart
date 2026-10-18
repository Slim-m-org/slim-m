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
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/screens/dm_call_pane.dart';
import 'package:slimm_app/src/features/channels/widgets/dm_row.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

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
      mockApiOverride((request) async {
        if (request.url.path.endsWith('/voice/roster')) {
          return http.Response(
            jsonEncode({'participants': roster}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 204);
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
  testWidgets('an empty roster shows no call icon', (tester) async {
    final channel = _dm('dm-1', 'Priya', 'user-priya');
    final container = _container(roster: const []);

    await tester.pumpWidget(_harness(container, _router(channel)));
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(AppIcons.startCall), findsNothing);
    container.dispose();
  });

  testWidgets(
    'a peer already on the call shows the call icon, and tapping the row '
    'opens straight into the call pane',
    (tester) async {
      final channel = _dm('dm-1', 'Priya', 'user-priya');
      final container = _container(
        roster: const [
          {'user_id': 'user-priya', 'display_name': 'Priya'},
        ],
      );

      await tester.pumpWidget(_harness(container, _router(channel)));
      await tester.pump();
      await tester.pump();

      expect(find.byIcon(AppIcons.startCall), findsOneWidget);
      expect(container.read(dmCallOpenProvider), isNull);

      await tester.tap(find.byType(DmRow));
      await tester.pumpAndSettle();

      expect(find.text('channel:dm-1'), findsOneWidget);
      expect(
        container.read(dmCallOpenProvider),
        'dm-1',
        reason: 'tapping a row with a call in progress must open into it',
      );
      container.dispose();
    },
  );

  testWidgets(
    'tapping a row with no call leaves dmCallOpenProvider untouched',
    (tester) async {
      final channel = _dm('dm-1', 'Priya', 'user-priya');
      final container = _container(roster: const []);

      await tester.pumpWidget(_harness(container, _router(channel)));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byType(DmRow));
      await tester.pumpAndSettle();

      expect(find.text('channel:dm-1'), findsOneWidget);
      expect(container.read(dmCallOpenProvider), isNull);
      container.dispose();
    },
  );
}
