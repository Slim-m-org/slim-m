// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the rail's Direct messages section: real DM channels (stored
/// locally under `kind == 'dm'`, see `providers/dms.dart`), and the footer's
/// Notes button that replaced the personal space row above them (decision
/// 0111's 2026-11-16 section).
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
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_notes_button.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/async_wait.dart';
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

/// A container wired with a signed-in session and an API client answering
/// `POST /dms/self`, with [onOpen] seeing every request. [personal] is put in
/// the local store first, as an account that has opened Notes before has it.
ProviderContainer _container({
  void Function(http.Request request)? onOpen,
  Channel? personal,
  bool openFails = false,
}) => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    // Without this, DmRow's voiceRosterProvider pulls in the real SyncController.
    liveEventsProvider.overrideWithValue(const Stream.empty()),
    databaseProvider.overrideWith((ref) async {
      final db = SlimmDatabase(NativeDatabase.memory());
      ref.onDispose(db.close);
      if (personal != null) await db.into(db.channels).insert(personal);
      return db;
    }),
    mockApiOverride((request) async {
      onOpen?.call(request);
      if (openFails && request.url.path == '/dms/self') {
        return http.Response(
          jsonEncode({'error': 'unavailable'}),
          503,
          headers: {'content-type': 'application/json'},
        );
      }
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
    body: DirectMessagesSection(
      channels: channels,
      selectedId: selectedId,
      listed: true,
    ),
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
  testWidgets('Direct messages has no Notes row, even with no DMs at all', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(_harness(container: container, channels: []));

    expect(
      find.text(personalSpaceName),
      findsNothing,
      reason: 'Notes is the button beside the gear now',
    );
    expect(find.textContaining('Start one from'), findsNothing);
    // Explicit: addTearDown runs after flutter_test's own pending-timer check.
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a real DM channel renders as a row, and Notes never does', (
    tester,
  ) async {
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

    expect(find.text('Priya'), findsOneWidget);
    expect(find.text(personalSpaceName), findsNothing);
    expect(find.textContaining('Start one from the member list'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a DM whose other participant set their own display name to the '
      'personal space sentinel is still an ordinary row that opens their '
      'channel', (tester) async {
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
              listed: true,
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
      find.text('channel:dm-imposter'),
      findsOneWidget,
      reason:
          'tapping the impostor row must open their own channel, never '
          'the caller\'s personal space',
    );
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
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
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
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
              listed: true,
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
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the Notes button opens Notes on the server the first time and '
      'goes straight there', (tester) async {
    final requests = <http.Request>[];
    final container = _container(onOpen: requests.add);
    await _pumpNotesButton(tester, container);

    await tester.tap(find.bySemanticsLabel('Notes'));
    await tester.pumpAndSettle();

    expect(requests.where((r) => r.url.path == '/dms/self'), hasLength(1));
    expect(find.text('channel:dm-self'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('the Notes button goes straight to a Notes this account already '
      'has, without asking the server again', (tester) async {
    final requests = <http.Request>[];
    final container = _container(
      onOpen: requests.add,
      personal: _dm('dm-self', personalSpaceName, isPersonalSpace: true),
    );
    await _pumpNotesButton(tester, container);

    await tester.tap(find.bySemanticsLabel('Notes'));
    await tester.pumpAndSettle();

    expect(
      requests.where((r) => r.url.path == '/dms/self'),
      isEmpty,
      reason: 'an already-open personal space needs no round trip',
    );
    expect(find.text('channel:dm-self'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a first open the server refuses stays put and leaves its '
      'sentence for the rail to show', (tester) async {
    final container = _container(openFails: true);
    await _pumpNotesButtonThen(tester, container);

    expect(find.textContaining('channel:'), findsNothing);
    expect(
      container.read(notesOpenFailureProvider),
      startsWith('Could not open Notes'),
    );
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });
}

Future<void> _pumpNotesButtonThen(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await _pumpNotesButton(tester, container);
  await tester.tap(find.bySemanticsLabel('Notes'));
  await pumpFrames(tester, frames: 20);
}

Future<void> _pumpNotesButton(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          body: Center(child: RailNotesButton(activeChannelId: null)),
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
}
