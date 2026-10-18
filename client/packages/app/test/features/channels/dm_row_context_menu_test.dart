// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The DM row's right-click/long-press menu: open, close it out of the
/// sidebar, mute or narrow to mentions only, and report/block the other
/// participant.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
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

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

ProviderContainer _container({
  List<String> blocked = const [],
  void Function(http.Request request)? onRequest,
}) {
  final db = SlimmDatabase(NativeDatabase.memory());
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      // Without this, DmRow's voiceRosterProvider pulls in the real SyncController.
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      databaseProvider.overrideWith((ref) async {
        ref.onDispose(db.close);
        return db;
      }),
      mockApiOverride((request) async {
        onRequest?.call(request);
        if (request.url.path == '/blocks') return _json(blocked);
        // DmRow now watches this; the list shape, not the 204 fallback below.
        if (request.url.path.endsWith('/voice/roster')) {
          return _json({'participants': <Object>[]});
        }
        if (request.url.path.startsWith(
              '/notification-preferences/channels/',
            ) &&
            request.method == 'PUT') {
          final channelId = request.url.pathSegments.last;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return _json({
            'channel_id': channelId,
            'preference': body['preference'],
          });
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

Future<void> _openMenu(WidgetTester tester) => tester.tapAt(
  tester.getCenter(find.byType(DmRow)),
  buttons: kSecondaryButton,
  kind: PointerDeviceKind.mouse,
);

void main() {
  testWidgets(
    'a right-click offers Open, Close DM, Mute, Mentions only, Report user and Block',
    (tester) async {
      final channel = _dm('dm-1', 'Priya', 'user-priya');
      final container = _container();

      await tester.pumpWidget(_harness(container, _router(channel)));
      await tester.pump();

      await _openMenu(tester);
      await tester.pumpAndSettle();

      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Close DM'), findsOneWidget);
      expect(find.text('Mute'), findsOneWidget);
      expect(find.text('Mentions only'), findsOneWidget);
      expect(find.text('Report user'), findsOneWidget);
      expect(find.text('Block'), findsOneWidget);
      expect(find.text('Unblock'), findsNothing);
      // Explicit: addTearDown runs after flutter_test's own pending-timer check.
      container.dispose();
    },
  );

  testWidgets('tapping Close DM hides it and removes the local channel row', (
    tester,
  ) async {
    final channel = _dm('dm-1', 'Priya', 'user-priya');
    String? hideRequest;
    final container = _container(
      onRequest: (request) {
        if (request.method == 'DELETE' &&
            request.url.path == '/dms/user-priya') {
          hideRequest = request.url.path;
        }
      },
    );
    final store = await container.read(storeProvider.future);
    await store.upsertChannels([
      const api.Channel(
        id: 'dm-1',
        name: 'Priya',
        kind: dmChannelKind,
        createdAt: 0,
        dmParticipantId: 'user-priya',
      ),
    ]);

    await tester.pumpWidget(_harness(container, _router(channel)));
    await tester.pump();

    await _openMenu(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close DM'));
    await tester.pumpAndSettle();

    expect(hideRequest, '/dms/user-priya');
    expect(await store.channelRow('dm-1'), isNull);
    container.dispose();
  });

  testWidgets('tapping Mute sets the channel override to nothing', (
    tester,
  ) async {
    final channel = _dm('dm-1', 'Priya', 'user-priya');
    final container = _container();

    await tester.pumpWidget(_harness(container, _router(channel)));
    await tester.pump();

    await _openMenu(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mute'));
    await tester.pumpAndSettle();

    expect(
      container.read(channelNotificationOverridesProvider).overrideFor('dm-1'),
      api.NotificationPreference.nothing,
    );
    container.dispose();
  });

  testWidgets('tapping the already-selected Mute again clears the override', (
    tester,
  ) async {
    final channel = _dm('dm-1', 'Priya', 'user-priya');
    final container = _container();
    await container
        .read(channelNotificationOverridesProvider.notifier)
        .mute('dm-1');

    await tester.pumpWidget(_harness(container, _router(channel)));
    await tester.pump();

    await _openMenu(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mute'));
    await tester.pumpAndSettle();

    expect(
      container.read(channelNotificationOverridesProvider).overrideFor('dm-1'),
      isNull,
      reason: 'tapping an already-active toggle is this menu\'s undo',
    );
    container.dispose();
  });

  testWidgets('an already-blocked peer offers Unblock, not Block again', (
    tester,
  ) async {
    final channel = _dm('dm-1', 'Priya', 'user-priya');
    final container = _container(blocked: const ['user-priya']);

    // Lets the block controller's own fetch settle before the menu reads it.
    await container.read(blocksProvider.notifier).refresh();

    await tester.pumpWidget(_harness(container, _router(channel)));
    await tester.pump();

    await _openMenu(tester);
    await tester.pumpAndSettle();

    expect(find.text('Unblock'), findsOneWidget);
    expect(find.text('Block'), findsNothing);
    container.dispose();
  });

  testWidgets('Open still reaches the channel route from the menu', (
    tester,
  ) async {
    final channel = _dm('dm-1', 'Priya', 'user-priya');
    final container = _container();

    await tester.pumpWidget(_harness(container, _router(channel)));
    await tester.pump();

    await _openMenu(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('channel:dm-1'), findsOneWidget);
    container.dispose();
  });
}
