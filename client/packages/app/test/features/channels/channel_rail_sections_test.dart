// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the rail's Direct messages section: real DM channels (stored
/// locally under `kind == 'dm'`, see `providers/dms.dart`), and the
/// always-present personal space row above them.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_latest_message_at.dart';
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Channel _dm(
  String id,
  String name, {
  int cursor = 0,
  int lastReadSeq = 0,
  bool isPersonalSpace = false,
}) => Channel(
  id: id,
  name: name,
  kind: dmChannelKind,
  createdAt: 0,
  position: 0,
  cursor: cursor,
  lastReadSeq: lastReadSeq,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: isPersonalSpace,
);

/// A container wired with a signed-in session and, when [onOpen] is given, an
/// API client answering `POST /dms/self`. Tests that never tap the personal
/// space row before it exists have nothing to answer, so [onOpen] stays null.
ProviderContainer _container({
  void Function(http.Request request)? onOpen,
}) => ProviderContainer(
  overrides: [
    // A live drift stream per row leaves its cleanup timer pending past the test.
    channelLatestMessageAtProvider.overrideWith(
      (ref, id) => Stream.value(null),
    ),
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    // Without this, DmRow's voiceRosterProvider pulls in the real SyncController.
    liveEventsProvider.overrideWithValue(const Stream.empty()),
    databaseProvider.overrideWith((ref) async {
      final db = SlimmDatabase(NativeDatabase.memory());
      ref.onDispose(db.close);
      return db;
    }),
    mockApiOverride((request) async {
      onOpen?.call(request);
      if (request.url.path.endsWith('/voice/roster')) {
        return http.Response(
          jsonEncode({'participants': <Object>[]}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'channel_id': 'dm-self',
          'user': {
            'id': 'self',
            'username': 'nick',
            'display_name': 'Nick',
            'created_at': 0,
          },
          'unread': 0,
          'created_at': 0,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  ],
);

Widget _harness({
  required ProviderContainer container,
  required List<Channel> channels,
  String? selectedId,
  GoRouter? router,
}) {
  final body = Scaffold(
    body: DirectMessagesSection(channels: channels, selectedId: selectedId),
  );
  final child = router == null
      ? MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: body,
        )
      : MaterialApp.router(
          theme: buildTheme(Brightness.light, AppTokens.light),
          routerConfig: router,
        );
  return UncontrolledProviderScope(container: container, child: child);
}

void main() {
  testWidgets(
    'the personal space row is always present, even with no DMs at all',
    (tester) async {
      final container = _container();
      await tester.pumpWidget(_harness(container: container, channels: []));

      expect(
        find.text(personalSpaceName),
        findsOneWidget,
        reason: 'it must be reachable before it has ever been opened',
      );
      expect(
        find.textContaining('Start one from the member list'),
        findsOneWidget,
      );
      // Explicit: addTearDown runs after flutter_test's own pending-timer check.
      container.dispose();
    },
  );

  testWidgets('a real DM channel renders as a row', (tester) async {
    final container = _container();
    await tester.pumpWidget(
      _harness(container: container, channels: [_dm('dm-1', 'Priya')]),
    );

    expect(find.text('Priya'), findsOneWidget);
    expect(find.text(personalSpaceName), findsOneWidget);
    expect(find.textContaining('Start one from the member list'), findsNothing);
    container.dispose();
  });

  testWidgets(
    'the personal space channel renders once, as the pinned row, never '
    'duplicated in the ordinary DM list',
    (tester) async {
      final container = _container();
      await tester.pumpWidget(
        _harness(
          container: container,
          channels: [
            _dm('dm-1', 'Priya'),
            _dm('dm-self', personalSpaceName, isPersonalSpace: true),
          ],
        ),
      );

      expect(find.text(personalSpaceName), findsOneWidget);
      expect(find.text('Priya'), findsOneWidget);
      container.dispose();
    },
  );

  testWidgets('a DM whose other participant set their own display name to the '
      'personal space sentinel is not rendered, or navigable, as the '
      'personal space', (tester) async {
    final container = _container();

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: DirectMessagesSection(
              // isPersonalSpace defaults to false: a matching label, no matching identity.
              channels: [_dm('dm-imposter', personalSpaceName)],
              selectedId: null,
            ),
          ),
        ),
        GoRoute(
          path: '/channels/:channelId',
          builder: (context, state) => Scaffold(
            body: Text('channel:${state.pathParameters['channelId']}'),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      _harness(container: container, channels: [], router: router),
    );

    // The always-present personal space row and the impostor's row both carry this label.
    expect(find.text(personalSpaceName), findsNWidgets(2));

    await tester.tap(find.text(personalSpaceName).last);
    await tester.pumpAndSettle();

    expect(
      find.text('channel:dm-imposter'),
      findsOneWidget,
      reason:
          'tapping the impostor row must open their own channel, never '
          'the caller\'s personal space',
    );
    container.dispose();
  });

  testWidgets('an unread DM shows the unread marker', (tester) async {
    final container = _container();
    await tester.pumpWidget(
      _harness(
        container: container,
        channels: [_dm('dm-1', 'Priya', cursor: 5, lastReadSeq: 2)],
      ),
    );

    expect(find.byKey(AppListRow.unreadDotKey), findsOneWidget);
    container.dispose();
  });

  testWidgets('tapping a DM opens its channel route', (tester) async {
    final container = _container();
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: DirectMessagesSection(
              channels: [_dm('dm-1', 'Priya')],
              selectedId: null,
            ),
          ),
        ),
        GoRoute(
          path: '/channels/:channelId',
          builder: (context, state) => Scaffold(
            body: Text('channel:${state.pathParameters['channelId']}'),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      _harness(container: container, channels: [], router: router),
    );

    await tester.tap(find.text('Priya'));
    await tester.pumpAndSettle();

    expect(find.text('channel:dm-1'), findsOneWidget);
    container.dispose();
  });

  testWidgets('tapping the personal space row before it exists opens it and '
      'navigates straight there', (tester) async {
    final requests = <http.Request>[];
    final container = _container(onOpen: requests.add);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            body: DirectMessagesSection(channels: [], selectedId: null),
          ),
        ),
        GoRoute(
          path: '/channels/:channelId',
          builder: (context, state) => Scaffold(
            body: Text('channel:${state.pathParameters['channelId']}'),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      _harness(container: container, channels: [], router: router),
    );

    await tester.tap(find.text(personalSpaceName));
    await tester.pumpAndSettle();

    // Filtered past the presence seed's own GET /members.
    final opens = requests.where((r) => r.url.path == '/dms/self');
    expect(opens, hasLength(1));
    expect(find.text('channel:dm-self'), findsOneWidget);
    container.dispose();
  });

  testWidgets('tapping the personal space row once it already exists navigates '
      'straight there without opening it again', (tester) async {
    final requests = <http.Request>[];
    final container = _container(onOpen: requests.add);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: DirectMessagesSection(
              channels: [
                _dm('dm-self', personalSpaceName, isPersonalSpace: true),
              ],
              selectedId: null,
            ),
          ),
        ),
        GoRoute(
          path: '/channels/:channelId',
          builder: (context, state) => Scaffold(
            body: Text('channel:${state.pathParameters['channelId']}'),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      _harness(container: container, channels: [], router: router),
    );

    await tester.tap(find.text(personalSpaceName));
    await tester.pumpAndSettle();

    expect(
      requests.where((r) => r.url.path == '/dms/self'),
      isEmpty,
      reason: 'an already-open personal space needs no round trip',
    );
    expect(find.text('channel:dm-self'), findsOneWidget);
    container.dispose();
  });
}
